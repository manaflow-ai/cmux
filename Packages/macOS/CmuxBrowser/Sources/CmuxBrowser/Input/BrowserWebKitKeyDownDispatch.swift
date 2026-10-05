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
    /// - Parameters:
    ///   - event: Canonical W3C/Playwright key metadata.
    ///   - action: Whether to send a press, key-down, or key-up.
    /// - Returns: The native delivery outcome, including whether the token is
    ///   outside the mapping or event creation failed.
    @discardableResult
    public func replayBrowserKeyboardEvent(
        _ event: BrowserKeyboardEvent,
        action: BrowserKeyboardAction
    ) -> BrowserKeyboardReplayResult {
        guard let nativeKey = event.nativeKey else {
            return .unsupported
        }

        if let modifierKey = nativeKey.modifierKey {
            return replayBrowserModifier(
                nativeKey,
                modifierKey: modifierKey,
                action: action
            )
        }

        let activeModifiers = browserNativeInputDeliveryOwner.activeModifierFlags
        let specification = SyntheticKeyEventFactory.specification(
            forBrowserNativeKey: nativeKey,
            additionalModifierFlags: activeModifiers
        )
        let result = replayBrowserKeyboardSpecification(
            specification,
            action: action,
            characters: nativeKey.characters,
            marksBrowserAutomation: true
        )
        // WebKit leaves Command+A/C/X/V/Z to the app's Edit menu by sending a
        // key no page handled back to the app, which drops an automated key's
        // resend; so once WebKit reports no page handled the key, run the
        // command on this web view, as the REPL does, never on the key
        // window. A key the page handled runs nothing more, as in a browser.
        if result == .delivered, action != .keyUp,
           let command = BrowserReplKeyStroke.editingCommand(code: event.code, key: event.key, flags: specification.modifierFlags),
           Self.menuEditingCommands.contains(command),
           let down = browserNativeInputDeliveryOwner.lastDeliveredKeyDown {
            let outcome = observeAutomationKeyDownOutcome(down)
            Task { @MainActor [weak self] in
                guard await outcome.wasUnhandled(), let self else { return }
                self.runAutomationEditingCommand(command)
            }
        }
        return result
    }

    /// Edit menu commands `cmux browser press` runs on the web view itself.
    static let menuEditingCommands: Set<String> = ["selectAll:", "copy:", "cut:", "paste:", "undo:", "redo:"]

    /// Routes an Edit menu command `cmux browser press` runs: returns `true`
    /// when the app ran it itself (a tab a REPL session created runs Copy,
    /// Cut and Paste on its own clipboard, never the system pasteboard).
    /// Set by the app; `nil` or `false` runs the web view's own action.
    public static var automationEditingCommandRoute: (@MainActor (WKWebView, String) -> Bool)?

    private func runAutomationEditingCommand(_ command: String) {
        if let route = WKWebView.automationEditingCommandRoute, route(self, command) { return }
        let selector = NSSelectorFromString(command)
        if responds(to: selector) { _ = perform(selector, with: nil) }
    }

    /// Starts watching `event`, an automated key-down this web view was just
    /// given, for whether a page handled it. Call it in the same main-actor
    /// turn as the delivery: WebKit reports the key's outcome only on a
    /// later turn. ``BrowserAutomationKeyDownOutcome/wasUnhandled(within:)``
    /// then says whether WebKit sent the key back to the app (no page
    /// handled it), which it does before it runs its callback for the end
    /// of the pending key events (`_doAfterProcessingAllPendingKeyEvents:`).
    public func observeAutomationKeyDownOutcome(_ event: NSEvent) -> BrowserAutomationKeyDownOutcome {
        let outcome = BrowserAutomationKeyDownOutcome(event: event)
        let selector = NSSelectorFromString("_doAfterProcessingAllPendingKeyEvents:")
        guard responds(to: selector) else {
            // Unknown: treated as handled, so nothing runs twice.
            outcome.resolve(unhandled: false)
            return outcome
        }
        BrowserAutomationKeyResends.shared.watch(event)
        let block: @convention(block) () -> Void = {
            MainActor.assumeIsolated {
                let reported = BrowserAutomationKeyResends.shared.finish(event)
                // WebKit makes the key the app's current event before it sends
                // it back; the app's drop (`reported`) names it exactly.
                let current = (NSApp as NSApplication?)?.currentEvent === event
                outcome.resolve(unhandled: reported || current)
            }
        }
        _ = perform(selector, with: block)
        return outcome
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

    init(event: NSEvent) {
        self.event = event
    }

    func resolve(unhandled: Bool) {
        guard !reported.isSignaled else { return }
        self.unhandled = unhandled
        reported.signal()
    }

    /// `true` once WebKit reported that no page handled the key; `false`
    /// when a page handled it, when WebKit has not reported within
    /// `timeout` (its web content ended meanwhile), or when this WebKit
    /// cannot report it. Never `true` for a key a page handled.
    public func wasUnhandled(within timeout: Duration = .seconds(5)) async -> Bool {
        let clock = ContinuousClock()
        guard await reported.wait(until: clock.now.advanced(by: timeout), clock: clock, honoringCancellation: false) else {
            BrowserAutomationKeyResends.shared.finish(event)
            return false
        }
        return unhandled
    }
}

/// Automated key-downs whose outcome is being watched, and whether the app
/// dropped WebKit's resend of each.
@MainActor
final class BrowserAutomationKeyResends {
    static let shared = BrowserAutomationKeyResends()

    private var watched: [ObjectIdentifier: (event: NSEvent, resent: Bool)] = [:]

    func watch(_ event: NSEvent) {
        watched[ObjectIdentifier(event)] = (event, false)
    }

    func noteResent(_ event: NSEvent) {
        let id = ObjectIdentifier(event)
        if let entry = watched[id], entry.event === event { watched[id] = (event, true) }
    }

    /// Stops watching `event`; returns whether its resend was dropped.
    @discardableResult
    func finish(_ event: NSEvent) -> Bool {
        guard let entry = watched.removeValue(forKey: ObjectIdentifier(event)) else { return false }
        return entry.resent
    }
}
