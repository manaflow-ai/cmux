/// Modifier keys relevant to terminal text-editing gesture resolution.
///
/// `TerminalTextEditingModifiers` is a small, platform-neutral option set that
/// lets the gesture resolver avoid depending on AppKit event types. The app
/// target maps `NSEvent.ModifierFlags` into this type before calling
/// ``terminalTextEditingResolve(keyCode:modifiers:)``.
///
/// This is deliberately separate from ``TerminalKeyboardCopyModeModifiers``,
/// which has no Option member because copy mode never needed one. Text editing
/// is built around Option, so it carries its own set rather than widening a
/// type that shipping copy-mode code depends on.
///
/// ```swift
/// let modifiers: TerminalTextEditingModifiers = [.option]
/// if modifiers.contains(.option) {
///     print("word-wise motion")
/// }
/// ```
public struct TerminalTextEditingModifiers: OptionSet, Equatable, Sendable {
    /// The raw option-set storage.
    public let rawValue: UInt8

    /// Creates a modifier set from raw option bits.
    ///
    /// - Parameter rawValue: The raw option-set storage. Unknown bits are
    ///   preserved so callers can round-trip values produced by `OptionSet`.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The Command modifier.
    public static let command = TerminalTextEditingModifiers(rawValue: 1 << 0)

    /// The Shift modifier.
    public static let shift = TerminalTextEditingModifiers(rawValue: 1 << 1)

    /// The Control modifier.
    public static let control = TerminalTextEditingModifiers(rawValue: 1 << 2)

    /// The Option modifier.
    public static let option = TerminalTextEditingModifiers(rawValue: 1 << 3)

    /// The numeric-pad modifier, ignored during gesture matching.
    public static let numericPad = TerminalTextEditingModifiers(rawValue: 1 << 4)

    /// The function-key modifier, ignored during gesture matching.
    public static let function = TerminalTextEditingModifiers(rawValue: 1 << 5)

    /// The caps-lock modifier, ignored during gesture matching.
    public static let capsLock = TerminalTextEditingModifiers(rawValue: 1 << 6)
}
