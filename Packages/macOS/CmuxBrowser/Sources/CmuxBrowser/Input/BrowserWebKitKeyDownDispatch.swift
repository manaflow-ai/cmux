public import AppKit
public import ObjectiveC
public import WebKit

@MainActor
public final class BrowserNativeInputDeliveryOwner {
    private var dispatchDepth = 0
    /// Modifier keys automation holds, by who holds them: each REPL
    /// session, and `""` for `cmux browser press`. A holder's events carry
    /// only its own, so one session's held Meta never turns another's key or
    /// click into a chord.
    private var heldModifierKeys: [HeldModifier: BrowserKeyboardNativeModifiers] = [:]

    private struct HeldModifier: Hashable {
        let holder: String
        let keyCode: UInt16
    }

    /// Creates an owner with no active dispatch and no held modifiers.
    public init() {}

    /// The last key-down this owner delivered to WebKit, for
    /// ``WKWebView/observeAutomationKeyDownOutcome(_:)``.
    public private(set) var lastDeliveredKeyDown: NSEvent?

    func recordDeliveredKeyDown(_ event: NSEvent) {
        lastDeliveredKeyDown = event
    }

    public var isDispatchActive: Bool { dispatchDepth > 0 }

    /// The modifier flags `cmux browser press` holds (holder `""`).
    public var activeModifierFlags: NSEvent.ModifierFlags { activeModifierFlags(heldBy: "") }

    /// The modifier flags `holder` holds.
    public func activeModifierFlags(heldBy holder: String) -> NSEvent.ModifierFlags {
        Self.flags(of: heldModifierKeys.filter { $0.key.holder == holder }.values)
    }

    /// The modifier flags `holder` holds, without the key `keyCode`.
    public func modifierFlags(removing keyCode: UInt16, heldBy holder: String = "") -> NSEvent.ModifierFlags {
        Self.flags(of: heldModifierKeys.filter { $0.key.holder == holder && $0.key.keyCode != keyCode }.values)
    }

    private static func flags(of modifiers: some Sequence<BrowserKeyboardNativeModifiers>) -> NSEvent.ModifierFlags {
        modifiers.reduce(into: NSEvent.ModifierFlags()) { flags, modifier in
            if modifier.contains(.shift) { flags.insert(.shift) }
            if modifier.contains(.control) { flags.insert(.control) }
            if modifier.contains(.option) { flags.insert(.option) }
            if modifier.contains(.command) { flags.insert(.command) }
            if modifier.contains(.capsLock) { flags.insert(.capsLock) }
            if modifier.contains(.function) { flags.insert(.function) }
        }
    }

    /// Runs `body`, this web view's native delivery of `event` (`nil`: a
    /// delivery that is not one key's, such as a mouse event).
    func withDispatch<T>(delivering event: NSEvent? = nil, _ body: () -> T) -> T {
        dispatchDepth += 1
        if let event { Self.deliveringEvents.append(event) }
        defer {
            dispatchDepth = max(0, dispatchDepth - 1)
            if let event, let index = Self.deliveringEvents.lastIndex(where: { $0 === event }) {
                Self.deliveringEvents.remove(at: index)
            }
        }
        return body()
    }

    /// The key events whose native delivery is in progress, in any web view.
    private static var deliveringEvents: [NSEvent] = []

    /// Whether `event` itself is being delivered to its web view right now.
    /// WebKit's resend of an unhandled key runs on a later turn, outside its
    /// own delivery; another web view's delivery in flight then (another
    /// tab's, another session's) is a different event and never covers it.
    public static func isDelivering(_ event: NSEvent) -> Bool {
        deliveringEvents.contains { $0 === event }
    }

    public func setModifier(_ modifier: BrowserKeyboardNativeModifiers, for keyCode: UInt16, heldBy holder: String = "") {
        heldModifierKeys[HeldModifier(holder: holder, keyCode: keyCode)] = modifier
    }

    public func removeModifier(for keyCode: UInt16, heldBy holder: String = "") {
        heldModifierKeys.removeValue(forKey: HeldModifier(holder: holder, keyCode: keyCode))
    }

    /// Forgets every modifier automation holds, for every holder.
    public func removeAllModifiers() {
        heldModifierKeys.removeAll()
    }

    fileprivate static let associationKey = BrowserNativeInputDeliveryOwnerAssociationKey()
}

private final class BrowserNativeInputDeliveryOwnerAssociationKey: NSObject {
}

@MainActor
extension WKWebView {
    /// Runs `body` while this web view's native WebKit key-down dispatch of
    /// `event` is marked active, so re-entrant key routing can tell that
    /// event is already on its way into WebKit.
    public func withBrowserWebKitKeyDownDispatch<T>(of event: NSEvent? = nil, _ body: () -> T) -> T {
        browserNativeInputDeliveryOwner.withDispatch(delivering: event, body)
    }
}

/// The outcome of delivering one browser automation key through AppKit.
public enum BrowserKeyboardReplayResult: Sendable, Equatable {
    /// The native event sequence was created and delivered to WebKit.
    case delivered

    /// The browser key has no macOS virtual-key representation.
    case unsupported

    /// A native event could not be created or a modifier transition could not be delivered.
    case eventCreationFailed

    /// An Edit menu shortcut (Select All, Copy, Cut, Paste, Undo, Redo, or a
    /// formatting shortcut) on a WebKit that cannot report whether a page
    /// handled its key (no `_doAfterProcessingAllPendingKeyEvents:`, as on
    /// macOS 26): nothing was delivered and no command ran
    /// (``WKWebView/canReportAutomationKeyDownOutcome``).
    case shortcutOutcomeUnavailable
}

@MainActor
extension CmuxWebView {
    func forwardKeyDownToWebKit(_ event: NSEvent) {
        browserNativeInputDeliveryOwner.withDispatch(delivering: event) {
            super.keyDown(with: event)
        }
    }
}

@MainActor
extension WKWebView {
    /// Replays a browser automation key through WebKit's native keyboard
    /// pipeline so the page receives a trusted DOM event and its default
    /// editing behavior can run (for example vertical contenteditable motion).
    ///
    /// For an Edit menu shortcut (``menuEditingCommands``) the key goes
    /// through ``deliverAutomationKeyDown(watchingOutcome:_:)``, as the
    /// REPL's do, and this returns once its command ran or was skipped.
    ///
    /// - Parameters:
    ///   - event: Canonical W3C/Playwright key metadata.
    ///   - action: Whether to send a press, key-down, or key-up.
    /// - Returns: The native delivery outcome, including whether the token is
    ///   outside the mapping or event creation failed.
    @discardableResult
    public func replayBrowserKeyboardEvent(
        _ event: BrowserKeyboardEvent,
        action: BrowserKeyboardAction
    ) async -> BrowserKeyboardReplayResult {
        let activeModifiers = browserNativeInputDeliveryOwner.activeModifierFlags
        guard let nativeKey = event.nativeKey?.resolvingLetterCase(held: activeModifiers) else {
            return .unsupported
        }

        if let modifierKey = nativeKey.modifierKey {
            return replayBrowserModifier(
                nativeKey,
                modifierKey: modifierKey,
                action: action
            )
        }

        let specification = SyntheticKeyEventFactory.specification(
            forBrowserNativeKey: nativeKey,
            additionalModifierFlags: activeModifiers
        )
        // WebKit leaves Command+A/C/X/V/Z to the app's Edit menu by sending a
        // key no page handled back to the app, which drops an automated key's
        // resend; so once WebKit reports no page handled the key, run the
        // command on this web view, as the REPL does, never on the key
        // window. A key the page handled runs nothing more, as in a browser.
        let command = action == .keyUp ? nil
            : BrowserReplKeyStroke.editingCommand(code: event.code, key: event.key, flags: specification.modifierFlags)
                .flatMap { Self.menuEditingCommands.contains($0) ? $0 : nil }
        let delivery = await deliverAutomationKeyDown(watchingOutcome: command != nil) {
            replayBrowserKeyboardSpecification(
                specification,
                action: action,
                characters: nativeKey.characters,
                marksBrowserAutomation: true
            )
        }
        if let command, let outcome = delivery.outcome, await outcome.wasUnhandled() {
            runAutomationEditingCommand(command)
        }
        return delivery.result
    }

    /// Delivers an automated key-down through `deliver`, the one path the
    /// REPL and `cmux browser press` send a key down on.
    ///
    /// With `watchingOutcome`, for a key whose Edit menu command runs only
    /// when no page handled it: first waits until WebKit's key queue is
    /// empty (``waitForQueuedAutomationKeyEvents(within:)``), since a key
    /// still in it (the previous key's key-up) would be taken for this
    /// one's and the outcome would say "handled"; then delivers and starts
    /// watching the delivered key-down in the same main-actor turn
    /// (``observeAutomationKeyDownOutcome(_:)``).
    ///
    /// With `watchingOutcome` on a WebKit that cannot report the outcome
    /// (``canReportAutomationKeyDownOutcome``), `deliver` does not run and
    /// the result is ``BrowserKeyboardReplayResult/shortcutOutcomeUnavailable``:
    /// guessing "unhandled" would run the command behind a page that took
    /// the key, guessing "handled" would drop it without a word.
    ///
    /// - Returns: `deliver`'s result, and the outcome to await when
    ///   `watchingOutcome` and a key-down was delivered.
    public func deliverAutomationKeyDown(
        watchingOutcome: Bool,
        _ deliver: () throws -> BrowserKeyboardReplayResult
    ) async rethrows -> (result: BrowserKeyboardReplayResult, outcome: BrowserAutomationKeyDownOutcome?) {
        guard watchingOutcome else { return (try deliver(), nil) }
        guard canReportAutomationKeyDownOutcome else { return (.shortcutOutcomeUnavailable, nil) }
        await waitForQueuedAutomationKeyEvents()
        let owner = browserNativeInputDeliveryOwner
        let previous = owner.lastDeliveredKeyDown
        let result = try deliver()
        guard result == .delivered, let down = owner.lastDeliveredKeyDown, down !== previous else {
            return (result, nil)
        }
        return (result, observeAutomationKeyDownOutcome(down))
    }

    private static let pendingKeyEventsSelector = NSSelectorFromString("_doAfterProcessingAllPendingKeyEvents:")

    /// Whether this WebKit can report if a page handled an automated
    /// key-down (``observeAutomationKeyDownOutcome(_:)``): it needs
    /// `_doAfterProcessingAllPendingKeyEvents:`, which macOS 26's WebKit
    /// lacks.
    public var canReportAutomationKeyDownOutcome: Bool {
        responds(to: Self.pendingKeyEventsSelector)
    }

    /// Edit menu commands `cmux browser press` runs on the web view itself.
    static let menuEditingCommands: Set<String> = ["selectAll:", "copy:", "cut:", "paste:", "undo:", "redo:"]

    /// The clipboard commands among ``menuEditingCommands``.
    static let clipboardEditingCommands: Set<String> = ["copy:", "cut:", "paste:"]

    /// Runs an Edit menu command `cmux browser press` sent. In a tab a REPL
    /// session created (its web view has the page clipboard guard,
    /// ``BrowserReplPageClipboard/isInstalled(on:)``) Copy, Cut and Paste
    /// run nothing: such a tab's clipboard is its session's virtual one, and
    /// `cmux browser press` carries no session, so it may neither reach that
    /// clipboard nor, as agent input, the system pasteboard.
    private func runAutomationEditingCommand(_ command: String) {
        if Self.clipboardEditingCommands.contains(command), BrowserReplPageClipboard.isInstalled(on: self) { return }
        // The app's web views keep their own undo stack; WKWebView has no
        // undo: or redo: of its own.
        if let undoable = self as? CmuxUndoableWebView, command == "undo:" || command == "redo:" {
            undoable.performWebContentUndoRedo(redo: command == "redo:")
            return
        }
        let selector = NSSelectorFromString(command)
        if responds(to: selector) { _ = perform(selector, with: nil) }
    }

    /// Starts watching `event`, an automated key-down this web view was just
    /// given, for whether a page handled it. Call it in the same main-actor
    /// turn as the delivery. ``BrowserAutomationKeyDownOutcome/wasUnhandled(within:)``
    /// then says whether WebKit sent the key back to the app (no page
    /// handled it).
    ///
    /// WebKit sends an unhandled key back before it runs its callback for
    /// the end of the pending key events (`_doAfterProcessingAllPendingKeyEvents:`),
    /// and the app's drop of that resend resolves the outcome at once. But
    /// in editable content of a web view in a window (the app's case) WebKit
    /// first gives the key to the window's input method and queues it for
    /// the page only on a later turn: a callback asked for before that runs
    /// at once, with no key pending, and says nothing about this key. So the
    /// callback is asked for again each time the main run loop is about to
    /// wait, until it no longer runs at once, which means WebKit has queued
    /// the key; its run then ends the key's processing.
    public func observeAutomationKeyDownOutcome(_ event: NSEvent) -> BrowserAutomationKeyDownOutcome {
        let outcome = BrowserAutomationKeyDownOutcome(event: event)
        let selector = Self.pendingKeyEventsSelector
        guard canReportAutomationKeyDownOutcome else {
            // Unknown: treated as handled, so nothing runs twice. The
            // shortcut paths never get here (deliverAutomationKeyDown
            // refuses them first).
            outcome.resolve(unhandled: false)
            return outcome
        }
        BrowserAutomationKeyResends.shared.watch(event, outcome: outcome)
        if !outcome.armPendingKeyEventsCallback(on: self, selector: selector) {
            outcome.armWhenTheRunLoopWaits(on: self, selector: selector)
        }
        return outcome
    }

    /// Waits, at most `timeout`, until WebKit has handled every key event it
    /// queued for the page. Call it before delivering a key-down whose
    /// outcome is watched (``observeAutomationKeyDownOutcome(_:)``): that
    /// watch tells the key is queued from WebKit's queue no longer being
    /// empty, which an earlier key still in the queue (the previous
    /// shortcut's key-up) would fake.
    public func waitForQueuedAutomationKeyEvents(within timeout: Duration = .seconds(5)) async {
        let selector = Self.pendingKeyEventsSelector
        guard canReportAutomationKeyDownOutcome else { return }
        let drained = BrowserReplLatch()
        let block: @convention(block) () -> Void = {
            MainActor.assumeIsolated { drained.signal() }
        }
        _ = perform(selector, with: block)
        let clock = ContinuousClock()
        _ = await drained.wait(until: clock.now.advanced(by: timeout), clock: clock, honoringCancellation: false)
    }

    /// Delivers an already-resolved AppKit key specification. The mobile
    /// browser stream and socket automation both use this seam so key-down
    /// re-entry handling and event construction cannot diverge.
    ///
    /// - Parameters:
    ///   - specification: AppKit key-code and modifier metadata.
    ///   - action: Whether to send a press, key-down, or key-up.
    ///   - characters: Optional Unicode text to attach to the event.
    ///   - marksBrowserAutomation: Marks the events as automation's
    ///     (``NSEvent/isBrowserAutomationKeyEvent``) so the app drops WebKit's
    ///     resend of one no page handled. The REPL and `cmux browser press`
    ///     mark their keys; the mobile browser stream, a person's keys from a
    ///     phone, does not, so its unhandled Command shortcuts still reach the
    ///     Mac's menus.
    /// - Returns: The native delivery outcome.
    @discardableResult
    public func replayBrowserKeyboardSpecification(
        _ specification: SyntheticKeySpecification,
        action: BrowserKeyboardAction,
        characters: String? = nil,
        marksBrowserAutomation: Bool = false
    ) -> BrowserKeyboardReplayResult {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = SyntheticKeyEventFactory.keyEvent(
            specification: specification,
            keyDown: true,
            timestamp: timestamp,
            characters: characters,
            marksBrowserAutomation: marksBrowserAutomation
        )
        let up = SyntheticKeyEventFactory.keyEvent(
            specification: specification,
            keyDown: false,
            timestamp: timestamp,
            characters: characters,
            marksBrowserAutomation: marksBrowserAutomation
        )

        switch action {
        case .press:
            guard let down, let up else { return .eventCreationFailed }
            deliverBrowserKeyDown(down)
            deliverBrowserKeyUp(up)
        case .keyDown:
            guard let down else { return .eventCreationFailed }
            deliverBrowserKeyDown(down)
        case .keyUp:
            guard let up else { return .eventCreationFailed }
            deliverBrowserKeyUp(up)
        }
        return .delivered
    }

    private func deliverBrowserKeyDown(_ event: NSEvent) {
        browserNativeInputDeliveryOwner.recordDeliveredKeyDown(event)
        if (123...126).contains(event.keyCode),
           let window,
           window.firstResponder === self {
            // WebKit's contenteditable line-navigation command is resolved by
            // the window text-input pipeline. Deliver arrows through the
            // already-focused window so the CGEvent retains its native context;
            // the dispatch-depth guard keeps cmux shortcut routing from seeing
            // the re-entry as a second user event.
            browserNativeInputDeliveryOwner.withDispatch(delivering: event) {
                window.sendEvent(event)
            }
            return
        }
        if let cmuxWebView = self as? CmuxWebView {
            cmuxWebView.forwardKeyDownToWebKit(event)
        } else {
            browserNativeInputDeliveryOwner.withDispatch(delivering: event) {
                keyDown(with: event)
            }
        }
    }

    private func deliverBrowserKeyUp(_ event: NSEvent) {
        browserNativeInputDeliveryOwner.withDispatch(delivering: event) {
            keyUp(with: event)
        }
    }

    public var browserNativeInputDeliveryOwner: BrowserNativeInputDeliveryOwner {
        if let owner = objc_getAssociatedObject(
            self,
            Unmanaged.passUnretained(BrowserNativeInputDeliveryOwner.associationKey).toOpaque()
        ) as? BrowserNativeInputDeliveryOwner {
            return owner
        }
        let owner = BrowserNativeInputDeliveryOwner()
        objc_setAssociatedObject(
            self,
            Unmanaged.passUnretained(BrowserNativeInputDeliveryOwner.associationKey).toOpaque(),
            owner,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return owner
    }

    func replayBrowserNativeModifier(
        _ key: BrowserKeyboardNativeKey,
        keyDown: Bool,
        heldBy holder: String = ""
    ) -> BrowserKeyboardReplayResult {
        guard let modifierKey = key.modifierKey else { return .unsupported }
        return replayBrowserModifier(key, modifierKey: modifierKey, action: keyDown ? .keyDown : .keyUp, heldBy: holder)
    }

    /// Sends a modifier key's `flagsChanged`, carrying the modifiers
    /// `holder` holds (``BrowserNativeInputDeliveryOwner``).
    private func replayBrowserModifier(
        _ key: BrowserKeyboardNativeKey,
        modifierKey: BrowserKeyboardNativeModifiers,
        action: BrowserKeyboardAction,
        heldBy holder: String = ""
    ) -> BrowserKeyboardReplayResult {
        guard let appKitFlag = Self.appKitModifierFlag(for: modifierKey) else {
            return .eventCreationFailed
        }

        switch action {
        case .press:
            let originalFlags = browserNativeInputDeliveryOwner.activeModifierFlags(heldBy: holder)
            let pressedFlags = originalFlags.union(appKitFlag)
            guard deliverBrowserFlagsChanged(key, flags: pressedFlags) else {
                return .eventCreationFailed
            }
            guard deliverBrowserFlagsChanged(key, flags: originalFlags) else {
                // Best-effort restoration keeps the WebKit modifier state from
                // remaining pressed when the release event cannot be created.
                _ = deliverBrowserFlagsChanged(key, flags: originalFlags)
                return .eventCreationFailed
            }
        case .keyDown:
            browserNativeInputDeliveryOwner.setModifier(modifierKey, for: key.keyCode, heldBy: holder)
            guard deliverBrowserFlagsChanged(key, flags: browserNativeInputDeliveryOwner.activeModifierFlags(heldBy: holder)) else {
                browserNativeInputDeliveryOwner.removeModifier(for: key.keyCode, heldBy: holder)
                return .eventCreationFailed
            }
        case .keyUp:
            let releasedFlags = browserNativeInputDeliveryOwner.modifierFlags(removing: key.keyCode, heldBy: holder)
            guard deliverBrowserFlagsChanged(key, flags: releasedFlags) else {
                _ = deliverBrowserFlagsChanged(key, flags: releasedFlags)
                return .eventCreationFailed
            }
            browserNativeInputDeliveryOwner.removeModifier(for: key.keyCode, heldBy: holder)
        }
        return .delivered
    }

    private func deliverBrowserFlagsChanged(
        _ key: BrowserKeyboardNativeKey,
        flags: NSEvent.ModifierFlags
    ) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: key.keyCode
        ) else {
            return false
        }
        browserNativeInputDeliveryOwner.withDispatch(delivering: event) {
            flagsChanged(with: event)
        }
        return true
    }

    private static func appKitModifierFlag(
        for modifier: BrowserKeyboardNativeModifiers
    ) -> NSEvent.ModifierFlags? {
        switch modifier {
        case .shift: return .shift
        case .control: return .control
        case .option: return .option
        case .command: return .command
        case .capsLock: return .capsLock
        case .function: return .function
        default: return nil
        }
    }
}

/// Keys browser automation (the REPL, `cmux browser press`) delivers to a
/// web view; the mobile browser stream's keys, a person's, are not marked. When no page handles such a key,
/// WebKit sends it back through `NSApp.sendEvent` (WebViewImpl's
/// doneWithKeyEvent), which hands it to the key window: the user's window,
/// whose first responder (a terminal) would receive the text and whose menus
/// would run Command shortcuts. The page has already received the key, so the
/// app drops that resend (``isResentBrowserAutomationKeyEvent``).
extension NSEvent {
    /// `CGEventField.eventSourceUserData` of an automated browser key ("cmuxkeys").
    static let browserAutomationKeyMark: Int64 = 0x636D_7578_6B65_7973

    /// Whether browser automation created this key event for a web view.
    public var isBrowserAutomationKeyEvent: Bool {
        guard type == .keyDown || type == .keyUp || type == .flagsChanged, let cgEvent else { return false }
        return cgEvent.getIntegerValueField(.eventSourceUserData) == Self.browserAutomationKeyMark
    }

    /// Whether this is an automated browser key reaching the app outside its
    /// own delivery to its web view (``BrowserNativeInputDeliveryOwner/isDelivering(_:)``):
    /// WebKit's resend of a key no page handled.
    @MainActor
    public var isResentBrowserAutomationKeyEvent: Bool {
        isBrowserAutomationKeyEvent && !BrowserNativeInputDeliveryOwner.isDelivering(self)
    }

    /// For the app's `sendEvent`: whether to drop this event as WebKit's
    /// resend of an automated key no page handled
    /// (``isResentBrowserAutomationKeyEvent``). A dropped key-down is
    /// recorded for ``WKWebView/observeAutomationKeyDownOutcome(_:)``.
    @MainActor
    public func dropResentBrowserAutomationKeyEvent() -> Bool {
        guard isResentBrowserAutomationKeyEvent else { return false }
        BrowserAutomationKeyResends.shared.noteResent(self)
        return true
    }
}

/// Whether a page handled one automated key-down
/// (``WKWebView/observeAutomationKeyDownOutcome(_:)``).
@MainActor
public final class BrowserAutomationKeyDownOutcome {
    private let event: NSEvent
    private let reported = BrowserReplLatch()
    private var unhandled = false
    private var waitObserver: CFRunLoopObserver?

    init(event: NSEvent) {
        self.event = event
    }

    func resolve(unhandled: Bool) {
        stopWaitingForTheQueue()
        guard !reported.isSignaled else { return }
        self.unhandled = unhandled
        reported.signal()
    }

    /// Asks WebKit for its callback after the pending key events. Returns
    /// false when the callback ran at once (no key was pending, so this key
    /// is not queued yet) and resolved nothing.
    func armPendingKeyEventsCallback(on webView: WKWebView, selector: Selector) -> Bool {
        guard !reported.isSignaled else { return true }
        var arming = true
        var ranAtOnce = false
        let event = self.event
        let block: @convention(block) () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                if arming {
                    ranAtOnce = true
                    return
                }
                BrowserAutomationKeyResends.shared.finish(event)
                // The app's drop of WebKit's resend resolved the outcome
                // already (`noteResent`). WebKit also makes the key the
                // app's current event before it sends it back.
                let current = (NSApp as NSApplication?)?.currentEvent === event
                self?.resolve(unhandled: current)
            }
        }
        _ = webView.perform(selector, with: block)
        arming = false
        return !ranAtOnce
    }

    /// Asks for the callback again each time the main run loop is about to
    /// wait (the input method's answer comes in between), until WebKit has
    /// queued the key or the outcome is resolved.
    func armWhenTheRunLoopWaits(on webView: WKWebView, selector: Selector) {
        guard waitObserver == nil, !reported.isSignaled else { return }
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { [weak self, weak webView] observer, _ in
            MainActor.assumeIsolated {
                guard let self else {
                    // An outcome nobody kept: stop asking for it.
                    if let observer { CFRunLoopObserverInvalidate(observer) }
                    return
                }
                guard let webView else {
                    self.stopWaitingForTheQueue()
                    return
                }
                if self.armPendingKeyEventsCallback(on: webView, selector: selector) {
                    self.stopWaitingForTheQueue()
                }
            }
        }
        guard let observer else { return }
        waitObserver = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func stopWaitingForTheQueue() {
        guard let observer = waitObserver else { return }
        waitObserver = nil
        CFRunLoopObserverInvalidate(observer)
    }

    /// `true` once WebKit reported that no page handled the key; `false`
    /// when a page handled it, when WebKit has not reported within
    /// `timeout` (its web content ended meanwhile), or when this WebKit
    /// cannot report it. Never `true` for a key a page handled.
    public func wasUnhandled(within timeout: Duration = .seconds(5)) async -> Bool {
        let clock = ContinuousClock()
        guard await reported.wait(until: clock.now.advanced(by: timeout), clock: clock, honoringCancellation: false) else {
            BrowserAutomationKeyResends.shared.finish(event)
            stopWaitingForTheQueue()
            return false
        }
        return unhandled
    }
}

/// Automated key-downs whose outcome is being watched. An entry holds its
/// outcome weakly: whoever awaits the outcome keeps it, and one nobody
/// keeps any longer goes away with its run-loop watch
/// (``BrowserAutomationKeyDownOutcome/armWhenTheRunLoopWaits(on:selector:)``
/// stops itself once its outcome is gone), never held here until WebKit
/// reports. Such an entry is dropped the next time a key is watched.
@MainActor
final class BrowserAutomationKeyResends {
    static let shared = BrowserAutomationKeyResends()

    private struct Watched {
        let event: NSEvent
        weak var outcome: BrowserAutomationKeyDownOutcome?
    }

    private var watched: [ObjectIdentifier: Watched] = [:]

    func watch(_ event: NSEvent, outcome: BrowserAutomationKeyDownOutcome) {
        watched = watched.filter { $0.value.outcome != nil }
        watched[ObjectIdentifier(event)] = Watched(event: event, outcome: outcome)
    }

    /// WebKit sent `event` back to the app: no page handled it. Its outcome
    /// is resolved now, whenever WebKit's pending-keys callback comes.
    func noteResent(_ event: NSEvent) {
        let id = ObjectIdentifier(event)
        guard let entry = watched[id], entry.event === event else { return }
        watched.removeValue(forKey: id)
        entry.outcome?.resolve(unhandled: true)
    }

    /// Stops watching `event`.
    func finish(_ event: NSEvent) {
        watched.removeValue(forKey: ObjectIdentifier(event))
    }
}
