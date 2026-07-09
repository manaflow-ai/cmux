public import AppKit

/// The keyboard shortcut that triggers browser "paste as plain text" (Cmd+Shift+V).
///
/// Holds the hardware key code for the V key (`9`, a layout-independent physical
/// position) and decides, from a key event's raw key code plus its modifier flags,
/// whether the event is the paste-as-plain-text command equivalent. The caller
/// passes the `keyCode` and `NSEvent.ModifierFlags` in so this type stays free of
/// any `NSEvent` dependency; `CmuxWebView` holds one instance and forwards the
/// event's components into ``matches(keyCode:modifierFlags:)``.
///
/// Faithfully lifted from the app target's private `CmuxWebView.pasteAsPlainTextKeyCode`
/// constant and `isPasteAsPlainTextCommandEquivalent(_:)`. The flag normalization
/// (intersect ``AppKit/NSEvent/ModifierFlags/deviceIndependentFlagsMask``, then
/// subtract `numericPad`, `function`, and `capsLock`) and the exact
/// `[.command, .shift]` equality are byte-identical to the legacy check.
public struct BrowserPasteAsPlainTextShortcut: Sendable, Equatable {
    /// The hardware key code for the V key (layout-independent physical position).
    /// Matches the legacy `pasteAsPlainTextKeyCode` (`9`).
    public let keyCode: UInt16

    /// Creates a paste-as-plain-text shortcut bound to a hardware key code.
    /// - Parameter keyCode: The layout-independent key code that, with Cmd+Shift,
    ///   triggers paste as plain text. Defaults to `9`, the V key's physical position.
    public init(keyCode: UInt16 = 9) {
        self.keyCode = keyCode
    }

    /// Whether a key event is the paste-as-plain-text command equivalent.
    /// - Parameters:
    ///   - keyCode: The event's raw `keyCode` (e.g. `NSEvent.keyCode`).
    ///   - modifierFlags: The event's `modifierFlags`.
    /// - Returns: `true` when the key code is ``keyCode`` and the normalized
    ///   modifiers are exactly Command+Shift.
    public func matches(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        let normalizedFlags = flags.subtracting([.numericPad, .function, .capsLock])
        return keyCode == self.keyCode && normalizedFlags == [.command, .shift]
    }
}
