import AppKit
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextDesign
import CmuxNextWakeups
import CmuxNextTerminal
import CmuxNextSettings
import CmuxNextSignposts
import CmuxNextFocusUI
import CmuxNextInput
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
///   run never takes focus from the user's frontmost app.
final class CmuxApplication: NSApplication, CEFAppProtocol {
    private var handlingSendEvent = false
    /// The event in dispatch reached AppKit's `sendEvent` (no cmux stage consumed it): the tap's
    /// dispatch-end outcome. A nested dispatch keeps its own and gives the outer one back.
    private var dispatchDelivered = false
    /// Set once in `CmuxNextApp.shared.main` before `run()`.
    var refusesActivation = false
    /// Set once by `AppServices`. Gets the key-down and the window it goes
    /// to; returns true when it consumed the key.
    var keyDownInterceptor: ((NSEvent, NSWindow?) -> Bool)?
    /// Set once in `CmuxNextApp.shared.main` before `run()`: the app's one input tap (the
    /// `AppDelegate`'s). Its observers see every event first (input journal), its intercepts run
    /// before AppKit dispatches the event, and its after-dispatch observers see a click once focus
    /// has moved to the clicked pane.
    var inputTap: InputEventTap?
    /// Set once by `AppServices`: opens an input latency slot for each tracked event and finishes it after its
    /// dispatch (`InputLatencyDispatch`, Chrome's EventLatency).
    var inputLatency: InputLatencyDispatch?
    /// Set once by `AppServices`: true when a key-down typed into one cmux window would reach
    /// another, the key window (`CrossWindowInputGuard`): the key is dropped.
    var crossWindowKeyGuard: ((NSEvent, NSWindow?) -> Bool)?
    /// Set once by `AppServices`: runs a click's or key's dispatch with the window it came from as
    /// the active window (`WindowManager.dispatching(eventFrom:_:)`).
    var dispatchScope: ((NSEvent, () -> Void) -> Void)?
    /// The event in dispatch is the app's own synthetic input
    /// (`SyntheticInput`, `debug.mouse`), classified once per event: the
    /// no-activate guard and the browser host's user-input path both read it.
    private(set) var currentEventIsSynthetic = false
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app")

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
    /// `currentEvent` (the last dequeued one, kept after its dispatch). It tells the main-thread scheduler
    /// about each discrete input and whether its turn expects a frame (`MainWorkScheduler.noteDiscreteInput(expectsFrame:)`).
    var inputDispatch: InputDispatchContext?

    /// Each window's continuous input, coalesced to its frame (`FrameInputCoalescer`). `sendEvent`
    /// flushes it before every discrete event; owners that post get it by injection.
    private(set) lazy var frameInput = FrameInputCoalescers()

    @objc(setHandlingSendEvent:)
    func setHandlingSendEvent(_ value: Bool) { handlingSendEvent = value }

    /// Set once in `CmuxNextApp.main` while feature `mainJobGate` is on: each event's
    /// route is marked as a dispatch on its word, so the main-actor jobs the route enqueues pass it.
    var jobGate: MainJobGateSwitch?

    /// The main-thread budget's run-loop turn meter (``meterTurns(_:)``).
    private var turnMeter: MainTurnMeter?

    /// Times every main run-loop turn on `meter`, each `sendEvent` as its input-dispatch span. Called
    /// once in `CmuxNextApp.main`, before `run()`.
    func meterTurns(_ meter: MainTurnMeter) {
        turnMeter = meter
        meter.observe()
    }

    /// Set once by `AppDelegate` when the watchdog starts: each user key, click and wheel event's queueing
    /// (its OS time to the turn meter's dispatch stamp) goes to the watchdog's input-queueing histogram
    /// (`debug.hangs` `turn_histogram`).
    var inputQueueing: MainThreadWatchdog?

    // perf-hot: 100ns main-turn (every event's dispatch: the turn meter's input span)
    override func sendEvent(_ event: NSEvent) {
        let outerDelivered = dispatchDelivered
        dispatchDelivered = false
        inputTap?.sendEventBegan(event)
        defer { dispatchDelivered = outerDelivered; inputTap?.sendEventEnded() }
        if let turnMeter { turnMeter.stampedInputDispatch { tapped(event, dispatchedNanos: $0) } } else { tapped(event, dispatchedNanos: nil) }
        // Every path, outside the turn meter's input span and the tap's dispatch scope.
        inputTap?.deliverDispatchEnd(event, outcome: dispatchDelivered ? .delivered : .consumed)
    }

    /// A menu item's action: its tracking event answers it (`InputEventTap.actionEvent`), in or out of a dispatch.
    override func sendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool {
        guard sender is NSMenuItem, let inputTap else { return super.sendAction(action, to: target, from: sender) }
        inputTap.menuActionBegan()
        defer { inputTap.menuActionEnded() }
        return super.sendAction(action, to: target, from: sender)
    }

    private func tapped(_ event: NSEvent, dispatchedNanos: UInt64?) {
        // One tap dispatch scope per event: a subscription made in one stage never hears this event.
        guard let inputTap else { return dispatchInput(event, dispatchedNanos: dispatchedNanos) }
        inputTap.dispatching { dispatchInput(event, dispatchedNanos: dispatchedNanos) }
    }

    private func dispatchInput(_ event: NSEvent, dispatchedNanos: UInt64?) {
        guard let inputDispatch else { return route(event, dispatchedNanos: dispatchedNanos) }
        inputDispatch.dispatching(event) { route(event, dispatchedNanos: dispatchedNanos) }
    }

    private func route(_ event: NSEvent, dispatchedNanos: UInt64?) {
        let outerDispatch = jobGate?.beginDispatch()
        defer { if let outerDispatch { jobGate?.endDispatch(restoring: outerDispatch) } }
        // Every key-down: the probe opens a sample while it records and for its 1-in-16 key.echo_frame sample.
        let probesKey = event.type == .keyDown && TypingLatencyProbe.shared.keyDown(eventTimestamp: event.timestamp)
        defer { if probesKey { TypingLatencyProbe.shared.mark(.dispatchEnd) } }
        let previousSynthetic = currentEventIsSynthetic
        currentEventIsSynthetic = !SyntheticInput.isUserInput(event)
        defer { currentEventIsSynthetic = previousSynthetic }
        if let inputQueueing, let dispatchedNanos, Self.measuresQueueing(event.type, synthetic: currentEventIsSynthetic) {
            inputQueueing.noteInputDispatch(eventTimestamp: event.timestamp, dispatchedNanos: dispatchedNanos)
        }
        Self.deliverObserveStage(event, tap: inputTap, frameInput: frameInput)
        let previous = handlingSendEvent
        handlingSendEvent = true
        defer { handlingSendEvent = previous }
        // A key typed into one cmux window never reaches another (the key window changed since).
        if event.type == .keyDown, Self.dropsCrossWindowKey(event, keyWindow: keyWindow, using: crossWindowKeyGuard) { return }
        // One latency slot per tracked event that is dispatched (a dropped key has none); it also carries the
        // key.frame or key.scroll_frame interval (InputLatencyDispatch).
        let latencySlot = inputLatency?.willDispatch(event, synthetic: currentEventIsSynthetic, keyWindow: keyWindow ?? event.window)
        defer { if let latencySlot { inputLatency?.didDispatch(latencySlot, layoutTookScroll: inputDispatch?.layoutTookScroll ?? false) } }
        guard let dispatchScope, Self.scopesDispatch(event.type) else { return dispatch(event) }
        dispatchScope(event) { dispatch(event) }
    }

    /// The observe stage of one event: pending moves and scrolls run before a key, click or gesture,
    /// and before any tap observer sees it (Chromium's ShouldFlushQueue), then the tap's observers.
    static func deliverObserveStage(_ event: NSEvent, tap: InputEventTap?, frameInput: FrameInputCoalescers) {
        frameInput.willDispatch(event.type)
        if let tap { BenchSpans.measure("app.inputTap.observe") { tap.deliverObserve(event) } }
    }

    /// The input events whose queueing is measured: the user's own keys, clicks and wheel (Chromium's
    /// EventLatency kinds), never the app's synthetic input (`SyntheticInput`). A re-sent event (a held key
    /// replayed, a chord re-sent) is the watchdog's to skip: it is no newer than the newest it counted.
    static func measuresQueueing(_ type: NSEvent.EventType, synthetic: Bool) -> Bool {
        !synthetic && (scopesDispatch(type) || type == .keyUp || type == .scrollWheel)
    }

    /// The input events whose dispatch acts in the window they came from (`dispatchScope`).
    static func scopesDispatch(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp: true
        default: false
        }
    }

    private func dispatch(_ event: NSEvent) {
        if event.type == .keyDown, let keyDownInterceptor, keyDownInterceptor(event, keyWindow ?? event.window) { return }
        if event.type == .keyDown, FindPillView.forwardArrowKeyDownToEditingPill(event, in: keyWindow ?? event.window) { return }
        Self.dispatchThroughTap(event, tap: inputTap) { delivered in
            dispatchDelivered = true
            super.sendEvent(delivered)
        }
        // After AppKit handled the move: a browser toolbar under the pointer in a window that is
        // not key sets its cursor last (`ArrowCursorView.pointerDidMove`).
        if event.type == .mouseMoved { ArrowCursorView.pointerDidMove() }
    }

    override func target(forAction action: Selector, to target: Any?, from sender: Any?) -> Any? {
        let found = super.target(forAction: action, to: target, from: sender)
        guard target == nil, let actionTargetOverride else { return found }
        return actionTargetOverride(action, found as AnyObject?) ?? found
    }

    /// An exception AppKit caught on the main thread. With
    /// `NSApplicationCrashOnExceptions` (`CrashOnExceptions`) AppKit traps
    /// here and the uncaught-exception handler never runs, so the record is
    /// written first; the next launch's notice and report then name it.
    ///
    /// With crashing on, the crash has begun here: the crash deadline then
    /// ends the process even if a crash handler after this blocks. With it
    /// off, AppKit's loop goes on at the top level, and the turn meter goes
    /// back there too (the exception skipped its span ends and loop exits).
    override func reportException(_ exception: NSException) {
        turnMeter?.unwindToTopLevel()
        CrashReporter.reportException(exception, crashes: UserDefaults.standard.bool(forKey: CrashOnExceptions.key),
                                      record: UncaughtExceptionRecorder.handle) { super.reportException(exception) }
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
    override func accessibilityFocusedWindow() -> Any? {
        Self.redirect(super.accessibilityFocusedWindow())
    }

    override func accessibilityMainWindow() -> Any? {
        Self.redirect(super.accessibilityMainWindow())
    }

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
    private var assistiveRequests = AssistiveClientRequests()

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
        logger.info("activation refused (CMUX_NEXT_NO_ACTIVATE=1)")
    }
}

extension CmuxApplication {
    /// The gate follows `debug.mainJobGate` once the settings load (nil before: nothing installs).
    func followMainJobGate(_ settings: SettingsController, on mainWork: MainWorkScheduler) {
        jobGate?.follow(on: mainWork) { [weak settings] in
            guard let settings, settings.loadCount >= 1 else { return nil }
            return settings.snapshot.mainJobGate.enabled
        }
    }

    /// The tap's stages around AppKit's dispatch of `event`: its intercepts, then `superSend`
    /// (`-[NSApplication sendEvent:]`, where AppKit's local monitors run) unless an intercept
    /// consumed the event, then its after-dispatch observers. Intercepts and local monitors run in
    /// the same `sendEvent`, so they hear the same events: a release a nested tracking loop dequeues
    /// itself reaches neither (DragTapTrackingLoopTests drives this function).
    ///
    /// - Returns: What the intercepts did with the event.
    @discardableResult
    static func dispatchThroughTap(_ event: NSEvent, tap: InputEventTap?, superSend: (NSEvent) -> Void) -> InputEventTap.InterceptResult {
        let result = tap?.deliverIntercepts(event) ?? .pass
        if result != .consume {
            if event.type == .leftMouseDown || event.type == .leftMouseUp {
                BenchSpans.measure(event.type == .leftMouseDown ? "app.sendEvent.down" : "app.sendEvent.up") { superSend(event) }
            } else {
                superSend(event)
            }
        }
        let mouseDown = event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown
        if mouseDown { BenchSpans.measure("app.inputTap.afterDispatch") { tap?.deliverAfterDispatch(event) } } else { tap?.deliverAfterDispatch(event) }
        return result
    }

    /// The cross-window stage of a key-down: true when `keyGuard` (`CrossWindowInputGuard`) drops
    /// it. The guard runs only when the key window is not the window the key was typed into, so a
    /// key in the key window costs one window-number compare.
    static func dropsCrossWindowKey(_ event: NSEvent, keyWindow: NSWindow?, using keyGuard: ((NSEvent, NSWindow?) -> Bool)?) -> Bool {
        guard let keyGuard, let keyWindow, event.windowNumber != keyWindow.windowNumber else { return false }
        return keyGuard(event, keyWindow)
    }
}

/// What assistive clients asked of the app: VoiceOver sets `AXEnhancedUserInterface`, automation
/// drivers (cua) `AXManualAccessibility`, on the application element. The app wants Chromium's page
/// accessibility while either is on.
nonisolated struct AssistiveClientRequests: Equatable {
    static let attributes: Set<String> = ["AXEnhancedUserInterface", "AXManualAccessibility"]
    private var values: [String: Bool] = [:]

    var wantsAccessibility: Bool { values.values.contains(true) }

    /// Records `value` for `attribute`; false (nothing recorded) for an attribute no assistive
    /// client sets.
    mutating func set(_ value: Any?, for attribute: String) -> Bool {
        guard Self.attributes.contains(attribute) else { return false }
        values[attribute] = (value as? NSNumber)?.boolValue ?? false
        return true
    }

    /// What was set for `attribute`; nil for other attributes. Unset reads as false.
    func value(for attribute: String) -> Bool? {
        Self.attributes.contains(attribute) ? values[attribute] ?? false : nil
    }
}
