import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextCrashReporting
import CmuxNextDesign
import CmuxNextWakeups
import CmuxNextTerminal
import CmuxNextSignposts
import CmuxNextFocusUI
import os

/// Chromium's application protocols (base/message_loop/message_pump_apple.h,
/// include/cef_application_mac.h), declared under their Objective-C names.
/// The runtime keeps the first protocol registered under a name and remaps
/// later references to it, so the CEF shim's `@protocol(CefAppProtocol)` and
/// Chromium's `@protocol(CrAppProtocol)` resolve to these, and
/// `CmuxApplication` conforms statically: nothing is injected at runtime.
@objc(CrAppProtocol) protocol ChromiumAppProtocol: NSObjectProtocol {
    @objc(isHandlingSendEvent) func isHandlingSendEvent() -> Bool
}

@objc(CrAppControlProtocol) protocol ChromiumAppControlProtocol: ChromiumAppProtocol {
    @objc(setHandlingSendEvent:) func setHandlingSendEvent(_ handlingSendEvent: Bool)
}

@objc(CefAppProtocol) protocol CEFAppProtocol: ChromiumAppControlProtocol {}

/// The app's NSApplication.
///
/// - CEF: Chromium must know when an event is being dispatched through
///   `sendEvent:` (nested run loops, menu tracking), so this class tracks it
///   and conforms to `CefAppProtocol` before `CefInitialize`.
/// - Keys: every key-down of the process passes ``keyDownInterceptor`` (the
///   `KeyRouter`) before any window or responder, including Chromium page
///   windows that are key themselves, so system and navigation shortcuts
///   work whatever has focus (plans/cmux-next/focus.md section 5).
/// - `CMUX_NEXT_NO_ACTIVATE=1` (``refusesActivation``): every activation
///   request, from AppKit, CEF/Chromium, or app code, is dropped, so an agent
///   run never takes focus from the user's frontmost app. The startup of an update relaunch nobody
///   clicked refuses it too, for a few seconds (`InputVerificationService.endRelaunchBehind`).
final class CmuxApplication: NSApplication, CEFAppProtocol, ActivationRefusing {
    private var handlingSendEvent = false, sawKeyDown = false
    /// A click on the full-screen titlebar band that lands on a button of the window under it.
    private let fullScreenTitlebarPresses = FullScreenTitlebarPress()
    /// Set in `CmuxNextApp.main` before `run()`; an update relaunch's startup turns it
    /// off again when it ends (`InputVerificationService.endRelaunchBehind`).
    var refusesActivation = false
    /// Set once by `AppServices`. Gets the key-down and the window it goes
    /// to; returns true when it consumed the key.
    var keyDownInterceptor: ((NSEvent, NSWindow?) -> Bool)?
    /// A key-up or a mouse-down before AppKit dispatches it: true when it is taken (link hints hold a key-up behind its key-down).
    var keyUpOrClickInterceptor: ((NSEvent) -> Bool)?
    /// Set once by `AppServices`: sees every event first (input journal).
    var inputObserver: ((NSEvent) -> Void)?
    /// Set once by `AppServices`: true when a key-down typed into one cmux window would reach
    /// another, the key window (`CrossWindowInputGuard`): the key is dropped.
    var crossWindowKeyGuard: ((NSEvent, NSWindow?) -> Bool)?
    /// Set once by `AppServices`: runs a click's or key's dispatch with the window it came from as
    /// the active window (`WindowManager.dispatching(eventFrom:_:)`).
    var dispatchScope: ((NSEvent, () -> Void) -> Void)?
    /// Set once by `AppServices`: a mouse-down after AppKit dispatched it
    /// (focus has moved to the clicked pane), with its window.
    var mouseDownObserver: ((NSEvent) -> Void)?
    /// Set once by `AppServices`: a left mouse-up, or a left-button drag, after AppKit dispatched it.
    var leftButtonObserver: ((NSEvent) -> Void)?
    /// Set once by `AppServices`: a key-down, before anything handles it.
    var keyDownObserver: ((NSEvent) -> Void)?
    /// Where the left mouse-down in dispatch went down (screen coordinates), taken before AppKit
    /// dispatched it: a titlebar press's window drag has moved the window by the time it returns.
    private(set) var mouseDownScreenLocation: NSPoint?
    /// The event in dispatch is the app's own synthetic input
    /// (`SyntheticInput`, `debug.mouse`), classified once per event: the
    /// no-activate guard and the browser host's user-input path both read it.
    private(set) var currentEventIsSynthetic = false
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app"); private let wakeSignpost: Void = DisplaySleep.shared.onWake = { WakeFrameSignpost().begin(source: .display) } // switch.wake (idle ledger)

    /// Set once by `AppServices`: a nil-targeted action's target instead of
    /// the responder chain's (`found`), or nil to keep it. Paste commands
    /// that no text input of Home takes go to its message box this way
    /// (`PrimaryInputPasteRoute`), for menus, key equivalents and synthetic
    /// Cmd+V alike.
    var actionTargetOverride: ((Selector, AnyObject?) -> AnyObject?)?

    @objc(isHandlingSendEvent)
    func isHandlingSendEvent() -> Bool { handlingSendEvent }

    /// Set once by `AppServices`: every event `sendEvent` gets is dispatched inside it, so the
    /// router, the menu gate and the action signposts read the event given to `sendEvent`, not
    /// `currentEvent` (the last dequeued one, kept after its dispatch).
    var inputDispatch: InputDispatchContext?

    @objc(setHandlingSendEvent:)
    func setHandlingSendEvent(_ value: Bool) { handlingSendEvent = value }

    /// Nonisolated so that nothing runs before this check: the `@MainActor` entry check reads the
    /// runtime's executor record, and a record left dead by an exception that unwound a Swift job
    /// segfaulted there at random, minutes later (#44060, #44185). A dead record is cleared and
    /// logged (``SwiftExecutorFrames``), then the event goes on to the main actor.
    nonisolated override func sendEvent(_ event: NSEvent) {
        if let dead = SwiftExecutorFrames.recoverDeadRecord(in: "sendEvent") { UncaughtExceptionRecorder.reportLostExecutor(dead) }
        nonisolated(unsafe) let event = event // crash-allow: AppKit calls sendEvent: on the main thread only; the event never leaves it
        MainActor.assumeIsolated { dispatchEvent(event) } // main-proof: AppKit calls sendEvent: on the main thread only
    }

    private func dispatchEvent(_ event: NSEvent) {
        guard event.cmuxAllowsPinchZoom else { return }
        if let inputDispatch { inputDispatch.dispatching(event) { route(event) } } else { route(event) }
    }

    private func route(_ event: NSEvent) {
        if event.type == .keyDown {
            let terminal = (keyWindow ?? event.window)?.firstResponder is TerminalSurfaceView
            KeyFrameSignpost().begin(target: terminal ? .terminal : .view, eventTimestamp: event.timestamp)
            if !sawKeyDown { sawKeyDown = true; DebugTimings.markLaunch("first_key_down") } // startup-tti: the first key AppKit gave the app
        }
        let probesKey = event.type == .keyDown && TypingLatencyProbe.isEnabled
        if probesKey { TypingLatencyProbe.shared.keyDown(eventTimestamp: event.timestamp) }
        defer { if probesKey { TypingLatencyProbe.shared.mark(.dispatchEnd) } }
        let previousSynthetic = currentEventIsSynthetic
        currentEventIsSynthetic = !SyntheticInput.isUserInput(event)
        defer { currentEventIsSynthetic = previousSynthetic }
        BenchSpans.measure("app.inputObserver") { inputObserver?(event) }
        let previous = handlingSendEvent; handlingSendEvent = true
        defer { handlingSendEvent = previous }
        // A key typed into one cmux window never reaches another (the key window changed since).
        if event.type == .keyDown, let crossWindowKeyGuard, crossWindowKeyGuard(event, keyWindow) { return }
        guard let dispatchScope, Self.scopesDispatch(event.type) else { return dispatch(event) }
        dispatchScope(event) { dispatch(event) }
    }

    /// The input events whose dispatch acts in the window they came from (`dispatchScope`).
    static func scopesDispatch(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp: true
        default: false
        }
    }

    private func dispatch(_ event: NSEvent) {
        if event.type == .keyDown { keyDownObserver?(event) }
        if event.type == .leftMouseDown {
            mouseDownScreenLocation = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
        }
        if event.type == .keyDown {
            // Router-consumed keys never reach AppKit local event monitors.
            (Self.accessibilityWindow(for: keyWindow ?? event.window)?.windowController as? WindowController)?.hideShortcutHintsForKeyDown(event)
        }
        if event.type == .keyDown, let keyDownInterceptor, keyDownInterceptor(event, keyWindow ?? event.window) { return }
        if event.type == .keyDown, FindPillView.forwardArrowKeyDown(event, in: keyWindow ?? event.window) { return }
        if event.type == .keyUp || event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown, keyUpOrClickInterceptor?(event) == true { return }
        if fullScreenTitlebarPresses.take(event, in: event.window) { return }
        if event.type == .leftMouseDown || event.type == .leftMouseUp {
            BenchSpans.measure(event.type == .leftMouseDown ? "app.sendEvent.down" : "app.sendEvent.up") { super.sendEvent(event) }
        } else { super.sendEvent(event) }
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown { BenchSpans.measure("app.mouseDownObserver") { mouseDownObserver?(event) } }
        if event.type == .leftMouseUp || event.type == .leftMouseDragged { leftButtonObserver?(event) }
        // After AppKit handled the move: a browser toolbar under the pointer in a window that is
        // not key sets its cursor last (`ArrowCursorView.pointerDidMove`).
        if event.type == .mouseMoved { ArrowCursorView.pointerDidMove() }
    }

    override func target(forAction action: Selector, to target: Any?, from sender: Any?) -> Any? {
        let found = super.target(forAction: action, to: target, from: sender)
        guard target == nil, let actionTargetOverride else { return found }
        return actionTargetOverride(action, found as AnyObject?) ?? found
    }

    /// An exception AppKit caught on the main thread. With `NSApplicationCrashOnExceptions` AppKit traps
    /// here (no uncaught-exception handler runs), so the record is written first and the crash has begun.
    /// Nonisolated, no executor check: the exception unwound a Swift job, whose dead executor record the
    /// main-actor entry check read and segfaulted on at 0x1e before anything was recorded (#44899).
    nonisolated override func reportException(_ exception: NSException) {
        SwiftExecutorFrames.recoverDeadRecord(in: "reportException")
        CrashReporter.reportException(exception, crashes: UserDefaults.standard.bool(forKey: CrashOnExceptions.key),
                                      record: UncaughtExceptionRecorder.handle) { appKitReportException(exception) }
    }

    // MARK: Accessibility windows

    /// The window Accessibility clients see as this app's focused or main
    /// window when `window` is key or main. A Chromium page is a child
    /// `NSWindow` that becomes key while the page has the keyboard; window
    /// managers (Rectangle) move the AX focused window, so they must get the
    /// cmux window that owns the page, which carries the page with it. App
    /// panels (palette, editors) stay their own windows.
    static func accessibilityWindow(for window: NSWindow?) -> NSWindow? {
        var current = window
        while let child = current, !(child is NSPanel), let parent = child.parent { current = parent }
        return current
    }

    /// AppKit reports the key window, or with none the frontmost ordered
    /// window, which is a Chromium page window when a page is in front.
    override func accessibilityFocusedWindow() -> Any? { Self.redirect(super.accessibilityFocusedWindow()) }

    override func accessibilityMainWindow() -> Any? { Self.redirect(super.accessibilityMainWindow()) }

    private static func redirect(_ value: Any?) -> Any? {
        guard let window = value as? NSWindow else { return value }
        return accessibilityWindow(for: window)
    }

    // MARK: Assistive clients

    /// Set once by `AppServices`: whether an assistive client asks for the app's accessibility
    /// tree (Chromium pages build theirs only then, `CEFEngine.setAssistiveClientActive`). It is
    /// told the current state when set, so a client that asked before launch finished counts.
    var assistiveClientsChanged: ((Bool) -> Void)? {
        didSet { assistiveClientsChanged?(assistiveRequests.wantsAccessibility) }
    }
    private var assistiveRequests = AssistiveClientRequests(environment: ProcessInfo.processInfo.environment)

    nonisolated override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        guard AssistiveClientRequests.attributes.contains(attribute.rawValue), Thread.isMainThread else {
            return super.accessibilitySetValue(value, forAttribute: attribute)
        }
        let number = value as? NSNumber
        MainActor.assumeIsolated { // main-proof: checked Thread.isMainThread above
            let wanted = assistiveRequests.wantsAccessibility
            _ = assistiveRequests.set(number, for: attribute.rawValue)
            if assistiveRequests.wantsAccessibility != wanted { assistiveClientsChanged?(assistiveRequests.wantsAccessibility) }
        }
    }

    nonisolated override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool {
        AssistiveClientRequests.attributes.contains(attribute.rawValue) || super.accessibilityIsAttributeSettable(attribute)
    }

    nonisolated override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        guard AssistiveClientRequests.attributes.contains(attribute.rawValue), Thread.isMainThread else {
            return super.accessibilityAttributeValue(attribute)
        }
        let value = MainActor.assumeIsolated { assistiveRequests.value(for: attribute.rawValue) } // main-proof: checked Thread.isMainThread above
        return value.map { NSNumber(value: $0) }
    }

    // MARK: Activation

    override func activate() {
        guard !refusesActivation else { return logRefused() }
        super.activate()
    }

    /// Chromium and older AppKit paths still call this one.
    override func activate(ignoringOtherApps: Bool) {
        guard !refusesActivation else { return logRefused() }
        super.activate(ignoringOtherApps: ignoringOtherApps)
    }

    private func logRefused() {
        logger.info("activation refused (CMUX_NEXT_NO_ACTIVATE=1, or an update relaunch's startup)")
    }
}
