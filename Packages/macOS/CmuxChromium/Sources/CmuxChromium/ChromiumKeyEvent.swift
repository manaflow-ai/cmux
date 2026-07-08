/// A keyboard event forwarded to a Chromium session.
///
/// The shell builds a Blink `RawKeyDown`/`KeyUp` from ``keyCode`` and, for key
/// downs with non-empty ``text``, a follow-up `Char` event, so printable input
/// flows from `text` while navigation keys rely on the Windows key code.
public struct ChromiumKeyEvent: Sendable, Equatable {
    /// `true` for key down, `false` for key up.
    public let isKeyDown: Bool
    /// Windows virtual-key code (`VK_*`), which Blink uses for non-printable keys.
    public let keyCode: UInt32
    /// Characters produced by the key, empty for non-printable keys.
    public let text: String
    /// Raw `NSEvent.ModifierFlags` bits active during the event.
    public let modifiers: UInt32

    /// Creates a key event.
    ///
    /// - Parameters:
    ///   - isKeyDown: `true` for key down, `false` for key up.
    ///   - keyCode: Windows virtual-key code; use ``ChromiumKeyTranslation`` to derive it.
    ///   - text: Characters produced by the key; empty suppresses the `Char` event.
    ///   - modifiers: Raw `NSEvent.ModifierFlags` bits; defaults to none.
    public init(isKeyDown: Bool, keyCode: UInt32, text: String = "", modifiers: UInt32 = 0) {
        self.isKeyDown = isKeyDown
        self.keyCode = keyCode
        self.text = text
        self.modifiers = modifiers
    }
}
