import AppKit
import CmuxBrowser
import ObjectiveC
import WebKit

@MainActor
final class BrowserNativeInputDeliveryOwner {
    private var dispatchDepth = 0
    private var heldModifierKeys: [UInt16: BrowserKeyboardNativeModifiers] = [:]

    var isDispatchActive: Bool { dispatchDepth > 0 }

    var activeModifierFlags: NSEvent.ModifierFlags {
        heldModifierKeys.values.reduce(into: NSEvent.ModifierFlags()) { flags, modifier in
            if modifier.contains(.shift) { flags.insert(.shift) }
            if modifier.contains(.control) { flags.insert(.control) }
            if modifier.contains(.option) { flags.insert(.option) }
            if modifier.contains(.command) { flags.insert(.command) }
            if modifier.contains(.capsLock) { flags.insert(.capsLock) }
            if modifier.contains(.function) { flags.insert(.function) }
        }
    }

    func modifierFlags(removing keyCode: UInt16) -> NSEvent.ModifierFlags {
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
        defer { dispatchDepth = max(0, dispatchDepth - 1) }
        return body()
    }

    func setModifier(_ modifier: BrowserKeyboardNativeModifiers, for keyCode: UInt16) {
        heldModifierKeys[keyCode] = modifier
    }

    func removeModifier(for keyCode: UInt16) {
        heldModifierKeys.removeValue(forKey: keyCode)
    }

    fileprivate static let associationKey = BrowserNativeInputDeliveryOwnerAssociationKey()
}

private final class BrowserNativeInputDeliveryOwnerAssociationKey: NSObject {
}

@MainActor
func cmuxWithBrowserWebKitKeyDownDispatch<T>(
    for webView: WKWebView,
    _ body: () -> T
) -> T {
    webView.browserNativeInputDeliveryOwner.withDispatch(body)
}

/// The outcome of delivering one browser automation key through AppKit.
nonisolated enum BrowserKeyboardReplayResult: Sendable, Equatable {
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
    func replayBrowserKeyboardEvent(
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
        return replayBrowserKeyboardSpecification(
            specification,
            action: action,
            characters: nativeKey.characters
        )
    }

    /// Delivers an already-resolved AppKit key specification. The mobile
    /// browser stream and socket automation both use this seam so key-down
    /// re-entry handling and event construction cannot diverge.
    ///
    /// - Parameters:
    ///   - specification: AppKit key-code and modifier metadata.
    ///   - action: Whether to send a press, key-down, or key-up.
    ///   - characters: Optional Unicode text to attach to the event.
    /// - Returns: The native delivery outcome.
    @discardableResult
    func replayBrowserKeyboardSpecification(
        _ specification: SyntheticKeySpecification,
        action: BrowserKeyboardAction,
        characters: String? = nil
    ) -> BrowserKeyboardReplayResult {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = SyntheticKeyEventFactory.keyEvent(
            specification: specification,
            keyDown: true,
            timestamp: timestamp,
            characters: characters
        )
        let up = SyntheticKeyEventFactory.keyEvent(
            specification: specification,
            keyDown: false,
            timestamp: timestamp,
            characters: characters
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

    var browserNativeInputDeliveryOwner: BrowserNativeInputDeliveryOwner {
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
