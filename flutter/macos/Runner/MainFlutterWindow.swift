import Cocoa
import AVFoundation
import FlutterMacOS
import desktop_multi_window
// import bitsdojo_window_macos

import desktop_drop
import device_info_plus
import flutter_custom_cursor
import package_info_plus
import path_provider_foundation
import screen_retriever
import sqflite
// import tray_manager
import uni_links_desktop
import url_launcher_macos
import wakelock_plus
import window_manager
import window_size
import texture_rgba_renderer

@_silgen_name("rustdesk_set_macos_trackpad_suppression")
private func rustdeskSetMacosTrackpadSuppression(_ enabled: Int32) -> Int32

// Global state for relative mouse mode
// All properties and methods must be accessed on the main thread since they
// interact with NSEvent monitors, CoreGraphics APIs, and Flutter channels.
// Note: We avoid @MainActor to maintain macOS 10.14 compatibility.
class RelativeMouseState {
    static let shared = RelativeMouseState()

    var enabled = false
    var eventMonitor: Any?
    var deltaChannel: FlutterMethodChannel?
    var accumulatedDeltaX: CGFloat = 0
    var accumulatedDeltaY: CGFloat = 0

    private init() {}
}

private final class NativeTrackpadWindowState {
    weak var window: NSWindow?
    weak var view: NSView?
    let channel: FlutterMethodChannel
    let recognizer: NSGestureRecognizer
    var forwardingEnabled = false
    var gestureActive = false
    var touchIDs: [NativeTrackpadTouchIdentity: Int] = [:]
    var nextTouchID = 1

    init(
        window: NSWindow,
        view: NSView,
        channel: FlutterMethodChannel,
        recognizer: NSGestureRecognizer
    ) {
        self.window = window
        self.view = view
        self.channel = channel
        self.recognizer = recognizer
    }

    func reset() {
        gestureActive = false
        touchIDs.removeAll(keepingCapacity: true)
        nextTouchID = 1
    }
}

/// NSTouch identity values are stable by `isEqual`/`hash` for the lifetime of
/// a contact, but AppKit does not guarantee the same object pointer each time.
private struct NativeTrackpadTouchIdentity: Hashable {
    let value: NSCopying & NSObjectProtocol

    static func == (
        lhs: NativeTrackpadTouchIdentity,
        rhs: NativeTrackpadTouchIdentity
    ) -> Bool {
        lhs.value.isEqual(rhs.value)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(value.hash)
    }
}

private enum NativeTrackpadTouchResult {
    case ignored
    case began
    case updated
    case ended
    case cancelled
}

/// Receives AppKit's reliable raw indirect-touch lifecycle. It never prevents
/// another recognizer, so ordinary one/two-finger input keeps its normal path.
private final class NativeTrackpadGestureRecognizer: NSGestureRecognizer {
    private let handler: (NSEvent, Bool) -> NativeTrackpadTouchResult

    init(handler: @escaping (NSEvent, Bool) -> NativeTrackpadTouchResult) {
        self.handler = handler
        super.init(target: nil, action: nil)
        allowedTouchTypes = [.indirect]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func touchesBegan(with event: NSEvent) {
        super.touchesBegan(with: event)
        apply(handler(event, false), event: event)
    }

    override func touchesMoved(with event: NSEvent) {
        super.touchesMoved(with: event)
        apply(handler(event, false), event: event)
    }

    override func touchesEnded(with event: NSEvent) {
        super.touchesEnded(with: event)
        apply(handler(event, false), event: event)
    }

    override func touchesCancelled(with event: NSEvent) {
        super.touchesCancelled(with: event)
        apply(handler(event, true), event: event)
    }

    override func canPrevent(_ preventedGestureRecognizer: NSGestureRecognizer) -> Bool {
        return false
    }

    override func canBePrevented(by preventingGestureRecognizer: NSGestureRecognizer) -> Bool {
        return false
    }

    private func apply(_ result: NativeTrackpadTouchResult, event: NSEvent) {
        switch result {
        case .began:
            state = .began
        case .updated:
            state = state == .possible ? .began : .changed
        case .ended:
            state = .ended
        case .cancelled:
            state = .cancelled
        case .ignored:
            // Keep the recognizer eligible while a resting thumb remains;
            // later non-resting contacts may still form a valid gesture.
            let hasTrackedTouches = !event.touches(
                matching: .touching, in: view).isEmpty
            if !hasTrackedTouches && state == .possible {
                state = .failed
            }
        }
    }
}

/// Captures public AppKit indirect-touch snapshots without consuming ordinary
/// mouse or two-finger scrolling. Three-or-more-finger sequences are consumed
/// only while the pointer is inside a remote desktop canvas.
private final class NativeTrackpadMonitor {
    static let shared = NativeTrackpadMonitor()

    private var states: [Int: NativeTrackpadWindowState] = [:]
    private var eventMonitor: Any?
    private var suppressionRequested = false
    private var applicationObservers: [NSObjectProtocol] = []

    private init() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.gesture]) {
            [weak self] event in
            return self?.filterGestureEvent(event) ?? event
        }
        let center = NotificationCenter.default
        applicationObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.updateSuppressionRequest()
        })
        applicationObservers.append(center.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.deactivateForwarding()
            self?.updateSuppressionRequest(applicationActive: false)
        })
        applicationObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateSuppressionRequest()
        })
        applicationObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.deactivateForwarding(for: notification.object as? NSWindow)
            self?.updateSuppressionRequest()
        })
        applicationObservers.append(center.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.cancelActiveGestures()
            _ = rustdeskSetMacosTrackpadSuppression(0)
        })
        // Repair a snapshot left by an abnormal previous exit before a new
        // remote-control session can begin.
        _ = rustdeskSetMacosTrackpadSuppression(0)
    }

    func register(view: NSView?, channel: FlutterMethodChannel) {
        guard let view = view else { return }
        pruneClosedWindows()
        view.allowedTouchTypes = [.indirect]
        view.wantsRestingTouches = false

        let recognizer = NativeTrackpadGestureRecognizer {
            [weak self, weak view] event, cancelled in
            return self?.handleTouchEvent(
                event, in: view, cancelled: cancelled) ?? .ignored
        }
        view.addGestureRecognizer(recognizer)

        let registerWindow = { [weak self, weak view] in
            guard let self = self, let view = view,
                  let window = view.window else { return }
            if let previous = self.states[window.windowNumber],
               let previousView = previous.view {
                previousView.removeGestureRecognizer(previous.recognizer)
            }
            self.states[window.windowNumber] = NativeTrackpadWindowState(
                window: window, view: view, channel: channel,
                recognizer: recognizer)
        }
        if view.window == nil {
            DispatchQueue.main.async(execute: registerWindow)
        } else {
            registerWindow()
        }
    }

    @discardableResult
    func setForwarding(_ enabled: Bool, for window: NSWindow?) -> Bool {
        guard let window = window,
              let state = states[window.windowNumber] else { return false }
        if !enabled && state.gestureActive {
            send(phase: "cancel", touches: [], state: state)
            state.reset()
        }
        state.forwardingEnabled = enabled
        if enabled && !updateSuppressionRequest() {
            state.forwardingEnabled = false
            return false
        } else if !enabled {
            _ = updateSuppressionRequest()
        }
        return true
    }

    private func send(
        phase: String,
        touches: [[String: Any]],
        state: NativeTrackpadWindowState
    ) {
        state.channel.invokeMethod(
            "onTrackpadTouches",
            arguments: ["phase": phase, "touches": touches])
    }

    private func filterGestureEvent(_ event: NSEvent) -> NSEvent? {
        pruneClosedWindows()
        guard let window = event.window,
              let state = states[window.windowNumber],
              state.forwardingEnabled,
              state.gestureActive else { return event }
        return nil
    }

    private func handleTouchEvent(
        _ event: NSEvent,
        in view: NSView?,
        cancelled: Bool
    ) -> NativeTrackpadTouchResult {
        pruneClosedWindows()
        guard let window = event.window,
              let state = states[window.windowNumber],
              state.forwardingEnabled else { return .ignored }

        let touching = event.touches(matching: .touching, in: view)
            .filter { !$0.isResting }
        let wasActive = state.gestureActive

        if cancelled {
            if wasActive {
                send(phase: "cancel", touches: [], state: state)
                state.reset()
                return .cancelled
            }
            return .ignored
        }

        if touching.count >= 3 {
            var contacts: [[String: Any]] = []
            contacts.reserveCapacity(min(touching.count, 5))
            let orderedTouches = touching.sorted { lhs, rhs in
                let lhsIdentity = NativeTrackpadTouchIdentity(value: lhs.identity)
                let rhsIdentity = NativeTrackpadTouchIdentity(value: rhs.identity)
                let lhsID = state.touchIDs[lhsIdentity]
                let rhsID = state.touchIDs[rhsIdentity]
                if let lhsID = lhsID, let rhsID = rhsID {
                    return lhsID < rhsID
                }
                if lhsID != nil { return true }
                if rhsID != nil { return false }
                if lhsIdentity.value.hash != rhsIdentity.value.hash {
                    return lhsIdentity.value.hash < rhsIdentity.value.hash
                }
                let lhsPosition = lhs.normalizedPosition
                let rhsPosition = rhs.normalizedPosition
                if lhsPosition.x != rhsPosition.x {
                    return lhsPosition.x < rhsPosition.x
                }
                return lhsPosition.y < rhsPosition.y
            }
            for touch in orderedTouches.prefix(5) {
                let identity = NativeTrackpadTouchIdentity(value: touch.identity)
                let id: Int
                if let existing = state.touchIDs[identity] {
                    id = existing
                } else {
                    id = state.nextTouchID
                    state.nextTouchID += 1
                    state.touchIDs[identity] = id
                }
                let position = touch.normalizedPosition
                contacts.append([
                    "id": id,
                    "x": Int((position.x * 10_000).rounded()),
                    // AppKit's normalized Y axis points up; evdev points down.
                    "y": Int(((1.0 - position.y) * 10_000).rounded()),
                ])
            }
            contacts.sort { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }
            state.gestureActive = true
            send(phase: wasActive ? "update" : "begin", touches: contacts, state: state)
            return wasActive ? .updated : .began
        }

        if wasActive {
            send(phase: "end", touches: [], state: state)
            state.reset()
            return .ended
        }
        return .ignored
    }

    private func pruneClosedWindows() {
        for state in states.values where state.window == nil && state.gestureActive {
            send(phase: "cancel", touches: [], state: state)
            state.reset()
        }
        states = states.filter { $0.value.window != nil }
        _ = updateSuppressionRequest()
    }

    private func cancelActiveGestures(for window: NSWindow? = nil) {
        for state in states.values where
            state.gestureActive && (window == nil || state.window === window) {
            send(phase: "cancel", touches: [], state: state)
            state.reset()
        }
    }

    private func deactivateForwarding(for window: NSWindow? = nil) {
        for state in states.values where window == nil || state.window === window {
            if state.gestureActive {
                send(phase: "cancel", touches: [], state: state)
                state.reset()
            }
            state.forwardingEnabled = false
        }
    }

    @discardableResult
    private func updateSuppressionRequest(
        applicationActive: Bool? = nil
    ) -> Bool {
        let isActive = applicationActive ?? NSApp.isActive
        let requested = isActive && states.values.contains {
            $0.forwardingEnabled && $0.window?.isKeyWindow == true
        }
        guard requested != suppressionRequested else { return true }
        if rustdeskSetMacosTrackpadSuppression(requested ? 1 : 0) != 0 {
            suppressionRequested = requested
            return true
        } else {
            if requested {
                for state in states.values where state.forwardingEnabled {
                    if state.gestureActive {
                        send(phase: "cancel", touches: [], state: state)
                        state.reset()
                    }
                    state.forwardingEnabled = false
                }
            }
            NSLog("[RustDesk] Failed to %@ macOS workspace gestures",
                  requested ? "suspend" : "restore")
            return false
        }
    }
}

class MainFlutterWindow: NSWindow {
    override func awakeFromNib() {
        rustdesk_core_main();
        let flutterViewController = FlutterViewController.init()
        let windowFrame = self.frame
        self.contentViewController = flutterViewController
        self.setFrame(windowFrame, display: true)
        // register self method handler
        let registrar = flutterViewController.registrar(forPlugin: "RustDeskPlugin")
        setMethodHandler(registrar: registrar)

        RegisterGeneratedPlugins(registry: flutterViewController)

        FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
            // Register the plugin which you want access from other isolate.
            // DesktopLifecyclePlugin.register(with: controller.registrar(forPlugin: "DesktopLifecyclePlugin"))
            // Note: copy below from above RegisterGeneratedPlugins
            self.setMethodHandler(registrar: controller.registrar(forPlugin: "RustDeskPlugin"))
            DesktopDropPlugin.register(with: controller.registrar(forPlugin: "DesktopDropPlugin"))
            DeviceInfoPlusMacosPlugin.register(with: controller.registrar(forPlugin: "DeviceInfoPlusMacosPlugin"))
            FlutterCustomCursorPlugin.register(with: controller.registrar(forPlugin: "FlutterCustomCursorPlugin"))
            FPPPackageInfoPlusPlugin.register(with: controller.registrar(forPlugin: "FPPPackageInfoPlusPlugin"))
            PathProviderPlugin.register(with: controller.registrar(forPlugin: "PathProviderPlugin"))
            SqflitePlugin.register(with: controller.registrar(forPlugin: "SqflitePlugin"))
            // TrayManagerPlugin.register(with: controller.registrar(forPlugin: "TrayManagerPlugin"))
            UniLinksDesktopPlugin.register(with: controller.registrar(forPlugin: "UniLinksDesktopPlugin"))
            UrlLauncherPlugin.register(with: controller.registrar(forPlugin: "UrlLauncherPlugin"))
            WakelockPlusMacosPlugin.register(with: controller.registrar(forPlugin: "WakelockPlusMacosPlugin"))
            WindowSizePlugin.register(with: controller.registrar(forPlugin: "WindowSizePlugin"))
            TextureRgbaRendererPlugin.register(with: controller.registrar(forPlugin: "TextureRgbaRendererPlugin"))
        }

        super.awakeFromNib()
    }

    override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        hiddenWindowAtLaunch()
    }

    /// Override window theme.
    public func setWindowInterfaceMode(window: NSWindow, themeName: String) {
        window.appearance = NSAppearance(named: themeName == "light" ? .aqua : .darkAqua)
    }

    private func enableNativeRelativeMouseMode(channel: FlutterMethodChannel) -> Bool {
        assert(Thread.isMainThread, "enableNativeRelativeMouseMode must be called on the main thread")
        let state = RelativeMouseState.shared
        if state.enabled {
            // Already enabled: update the channel so this caller receives deltas.
            state.deltaChannel = channel
            return true
        }

        // Dissociate mouse from cursor position - this locks the cursor in place
        // Do this FIRST before setting any state
        let result = CGAssociateMouseAndMouseCursorPosition(0)
        if result != CGError.success {
            NSLog("[RustDesk] Failed to dissociate mouse from cursor position: %d", result.rawValue)
            return false
        }

        // Only set state after CG call succeeds
        state.deltaChannel = channel
        state.accumulatedDeltaX = 0
        state.accumulatedDeltaY = 0

        // Add local event monitor to capture mouse delta.
        // Note: Local event monitors are always called on the main thread,
        // so accessing main-thread-only state is safe here.
        state.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak state] event in
            guard let state = state else { return event }
            // Guard against race: mode may be disabled between weak capture and this check.
            guard state.enabled else { return event }
            let deltaX = event.deltaX
            let deltaY = event.deltaY

            if deltaX != 0 || deltaY != 0 {
                // Accumulate delta (main thread only - NSEvent local monitors always run on main thread)
                state.accumulatedDeltaX += deltaX
                state.accumulatedDeltaY += deltaY

                // Only send if we have integer movement
                let intX = Int(state.accumulatedDeltaX)
                let intY = Int(state.accumulatedDeltaY)

                if intX != 0 || intY != 0 {
                    state.accumulatedDeltaX -= CGFloat(intX)
                    state.accumulatedDeltaY -= CGFloat(intY)

                    // Send delta to Flutter (already on main thread)
                    state.deltaChannel?.invokeMethod("onMouseDelta", arguments: ["dx": intX, "dy": intY])
                }
            }

            return event
        }

        // Check if monitor was created successfully
        if state.eventMonitor == nil {
            NSLog("[RustDesk] Failed to create event monitor for relative mouse mode")
            // Re-associate mouse since we failed
            CGAssociateMouseAndMouseCursorPosition(1)
            state.deltaChannel = nil
            return false
        }

        // Set enabled LAST after everything succeeds
        state.enabled = true
        return true
    }

    private func disableNativeRelativeMouseMode() {
        assert(Thread.isMainThread, "disableNativeRelativeMouseMode must be called on the main thread")
        let state = RelativeMouseState.shared
        if !state.enabled { return }

        state.enabled = false

        // Remove event monitor
        if let monitor = state.eventMonitor {
            NSEvent.removeMonitor(monitor)
            state.eventMonitor = nil
        }

        state.deltaChannel = nil
        state.accumulatedDeltaX = 0
        state.accumulatedDeltaY = 0

        // Re-associate mouse with cursor position (non-blocking with async retry)
        let result = CGAssociateMouseAndMouseCursorPosition(1)
        if result != CGError.success {
            NSLog("[RustDesk] Failed to re-associate mouse with cursor position: %d, scheduling retry...", result.rawValue)
            // Non-blocking retry after 50ms
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                let retryResult = CGAssociateMouseAndMouseCursorPosition(1)
                if retryResult != CGError.success {
                    NSLog("[RustDesk] Retry failed to re-associate mouse: %d. Cursor may remain locked.", retryResult.rawValue)
                }
            }
        }
    }

    public func setMethodHandler(registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "org.rustdesk.rustdesk/host", binaryMessenger: registrar.messenger)
        let registrarView = registrar.view
        NativeTrackpadMonitor.shared.register(view: registrarView, channel: channel)
        channel.setMethodCallHandler({
            (call, result) -> Void in
                switch call.method {
                case "setWindowTheme":
                    let arg = call.arguments as! [String: Any]
                    let themeName = arg["themeName"] as? String
                    guard let window = registrar.view?.window else {
                        result(nil)
                        return
                    }
                    self.setWindowInterfaceMode(window: window,themeName: themeName ?? "light")
                    result(nil)
                    break;
                case "terminate":
                    NSApplication.shared.terminate(self)
                    result(nil)
                case "canRecordAudio":
                    switch AVCaptureDevice.authorizationStatus(for: .audio) {
                    case .authorized:
                        result(1)
                        break
                    case .notDetermined:
                        result(0)
                        break
                    default:
                        result(-1)
                        break
                    }
                case "requestRecordAudio":
                    AVCaptureDevice.requestAccess(for: .audio, completionHandler: { granted in
                        DispatchQueue.main.async {
                            result(granted)
                        }
                    })
                    break
                case "bumpMouse":
                    var dx = 0
                    var dy = 0

                    if let argMap = call.arguments as? [String: Any] {
                        dx = (argMap["dx"] as? Int) ?? 0
                        dy = (argMap["dy"] as? Int) ?? 0
                    }
                    else if let argList = call.arguments as? [Any] {
                        dx = argList.count >= 1 ? (argList[0] as? Int) ?? 0 : 0
                        dy = argList.count >= 2 ? (argList[1] as? Int) ?? 0 : 0
                    }

                    var mouseLoc: CGPoint

                    if let dummyEvent = CGEvent(source: nil) { // can this ever fail?
                        mouseLoc = dummyEvent.location
                    }
                    else if let screenFrame = NSScreen.screens.first?.frame {
                        // NeXTStep: Origin is lower-left of primary screen, positive is up
                        // Cocoa Core Graphics: Origin is upper-left of primary screen, positive is down
                        let nsMouseLoc = NSEvent.mouseLocation

                        mouseLoc = CGPoint(
                            x: nsMouseLoc.x,
                            y: NSHeight(screenFrame) - nsMouseLoc.y)
                    }
                    else {
                        result(false)
                        break
                    }

                    let newLoc = CGPoint(x: mouseLoc.x + CGFloat(dx), y: mouseLoc.y + CGFloat(dy))

                    CGDisplayMoveCursorToPoint(0, newLoc)

                    // By default, Cocoa suppresses mouse events briefly after a call to warp the
                    // cursor to a new location. This is good if you want to draw the user's
                    // attention to the fact that the mouse is now in a particular location, but
                    // it's bad in this case; we get called as part of the handling of edge
                    // scrolling, which means the mouse is typically still in motion, and we want
                    // the cursor to keep moving smoothly uninterrupted.
                    //
                    // This function's main action is to toggle whether the mouse cursor is
                    // associated with the mouse position, but setting it to true when it's
                    // already true has the side-effect of cancelling this motion suppression.
                    //
                    // However, we must NOT call this when relative mouse mode is active,
                    // as it would break the pointer lock established by enableNativeRelativeMouseMode.
                    if !RelativeMouseState.shared.enabled {
                        CGAssociateMouseAndMouseCursorPosition(1 /* true */)
                    }

                    result(true)

                case "enableNativeRelativeMouseMode":
                    let success = self.enableNativeRelativeMouseMode(channel: channel)
                    result(success)

                case "disableNativeRelativeMouseMode":
                    self.disableNativeRelativeMouseMode()
                    result(true)

                case "setNativeTrackpadForwarding":
                    let arg = call.arguments as? [String: Any]
                    let enabled = arg?["enabled"] as? Bool ?? false
                    let success = NativeTrackpadMonitor.shared.setForwarding(
                        enabled,
                        for: registrarView?.window)
                    result(success)

                default:
                    result(FlutterMethodNotImplemented)
                }
        })
    }
}
