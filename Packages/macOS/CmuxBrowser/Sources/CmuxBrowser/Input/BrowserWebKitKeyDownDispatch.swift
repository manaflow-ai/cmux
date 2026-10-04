public import AppKit
public import ObjectiveC
public import WebKit

@MainActor
public final class BrowserNativeInputDeliveryOwner {
    private var dispatchDepth = 0
    private var heldModifierKeys: [UInt16: BrowserKeyboardNativeModifiers] = [:]

    /// Creates an owner with no active dispatch and no held modifiers.
    public init() {}

    public var isDispatchActive: Bool { dispatchDepth > 0 }

    public var activeModifierFlags: NSEvent.ModifierFlags {
        heldModifierKeys.values.reduce(into: NSEvent.ModifierFlags()) { flags, modifier in
            if modifier.contains(.shift) { flags.insert(.shift) }
            if modifier.contains(.control) { flags.insert(.control) }
            if modifier.contains(.option) { flags.insert(.option) }
            if modifier.contains(.command) { flags.insert(.command) }
            if modifier.contains(.capsLock) { flags.insert(.capsLock) }
            if modifier.contains(.function) { flags.insert(.function) }
        }
    }

    public func modifierFlags(removing keyCode: UInt16) -> NSEvent.ModifierFlags {
        heldModifierKeys.filter { $0.key != keyCode }.values.reduce(into: NSEvent.ModifierFlags()) { flags, modifier in
            if modifier.contains(.shift) { flags.insert(.shift) }
            if modifier.contains(.control) { flags.insert(.control) }
            if modifier.contains(.option) { flags.insert(.option) }
            if modifier.contains(.command) { flags.insert(.command) }
            if modifier.contains(.capsLock) { flags.insert(.capsLock) }
            if modifier.contains(.function) { flags.insert(.function) }
        }
    }

    func withDispatch<T>(_ body: () -> T) -> T {
        dispatchDepth += 1
        Self.activeDispatchCount += 1
        defer {
            dispatchDepth = max(0, dispatchDepth - 1)
            Self.activeDispatchCount = max(0, Self.activeDispatchCount - 1)
        }
        return body()
    }

    /// Native key deliveries in progress in any web view.
    private static var activeDispatchCount = 0

    /// Whether any web view is delivering an automated key right now. WebKit's
    /// resend of an unhandled key runs on a later turn, outside every delivery.
    public static var isAnyDispatchActive: Bool { activeDispatchCount > 0 }

    /// Key codes of modifiers currently held by automation.
    public var heldModifierKeyCodes: [UInt16] {
        Array(heldModifierKeys.keys)
    }

    public func setModifier(_ modifier: BrowserKeyboardNativeModifiers, for keyCode: UInt16) {
        heldModifierKeys[keyCode] = modifier
    }

    public func removeModifier(for keyCode: UInt16) {
        heldModifierKeys.removeValue(forKey: keyCode)
    }

    fileprivate static let associationKey = BrowserNativeInputDeliveryOwnerAssociationKey()
}

private final class BrowserNativeInputDeliveryOwnerAssociationKey: NSObject {
}

@MainActor
extension WKWebView {
    /// Runs `body` while this web view's native WebKit key-down dispatch is
    /// marked active, so re-entrant key routing can tell the event is already
    /// on its way into WebKit.
    public func withBrowserWebKitKeyDownDispatch<T>(_ body: () -> T) -> T {
        browserNativeInputDeliveryOwner.withDispatch(body)
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
        browserNativeInputDeliveryOwner.withDispatch {
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
        // WebKit leaves Command+A/C/X/V/Z to the app's Edit menu, which the
        // resend of an automated key no longer reaches; run the command on
        // this web view, as the REPL does, never on the key window.
        if result == .delivered, action != .keyUp,
           let command = BrowserReplKeyStroke.editingCommand(code: event.code, key: event.key, flags: specification.modifierFlags),
           Self.menuEditingCommands.contains(command) {
            let selector = NSSelectorFromString(command)
            if responds(to: selector) { _ = perform(selector, with: nil) }
        }
        return result
    }

    /// Edit menu commands `cmux browser press` runs on the web view itself.
    static let menuEditingCommands: Set<String> = ["selectAll:", "copy:", "cut:", "paste:", "undo:", "redo:"]

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
        if (123...126).contains(event.keyCode),
           let window,
           window.firstResponder === self {
            // WebKit's contenteditable line-navigation command is resolved by
            // the window text-input pipeline. Deliver arrows through the
            // already-focused window so the CGEvent retains its native context;
            // the dispatch-depth guard keeps cmux shortcut routing from seeing
            // the re-entry as a second user event.
            browserNativeInputDeliveryOwner.withDispatch {
                window.sendEvent(event)
            }
            return
        }
        if let cmuxWebView = self as? CmuxWebView {
            cmuxWebView.forwardKeyDownToWebKit(event)
        } else {
            browserNativeInputDeliveryOwner.withDispatch {
                keyDown(with: event)
            }
        }
    }

    private func deliverBrowserKeyUp(_ event: NSEvent) {
        browserNativeInputDeliveryOwner.withDispatch {
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
        keyDown: Bool
    ) -> BrowserKeyboardReplayResult {
        guard let modifierKey = key.modifierKey else { return .unsupported }
        return replayBrowserModifier(key, modifierKey: modifierKey, action: keyDown ? .keyDown : .keyUp)
    }

    private func replayBrowserModifier(
        _ key: BrowserKeyboardNativeKey,
        modifierKey: BrowserKeyboardNativeModifiers,
        action: BrowserKeyboardAction
    ) -> BrowserKeyboardReplayResult {
        guard let appKitFlag = Self.appKitModifierFlag(for: modifierKey) else {
            return .eventCreationFailed
        }

        switch action {
        case .press:
            let originalFlags = browserNativeInputDeliveryOwner.activeModifierFlags
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
            browserNativeInputDeliveryOwner.setModifier(modifierKey, for: key.keyCode)
            guard deliverBrowserFlagsChanged(key, flags: browserNativeInputDeliveryOwner.activeModifierFlags) else {
                browserNativeInputDeliveryOwner.removeModifier(for: key.keyCode)
                return .eventCreationFailed
            }
        case .keyUp:
            let releasedFlags = browserNativeInputDeliveryOwner.modifierFlags(removing: key.keyCode)
            guard deliverBrowserFlagsChanged(key, flags: releasedFlags) else {
                _ = deliverBrowserFlagsChanged(key, flags: releasedFlags)
                return .eventCreationFailed
            }
            browserNativeInputDeliveryOwner.removeModifier(for: key.keyCode)
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
        browserNativeInputDeliveryOwner.withDispatch {
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

    /// Whether this is an automated browser key reaching the app outside the
    /// web view's own delivery: WebKit's resend of a key no page handled.
    @MainActor
    public var isResentBrowserAutomationKeyEvent: Bool {
        isBrowserAutomationKeyEvent && !BrowserNativeInputDeliveryOwner.isAnyDispatchActive
    }
}
