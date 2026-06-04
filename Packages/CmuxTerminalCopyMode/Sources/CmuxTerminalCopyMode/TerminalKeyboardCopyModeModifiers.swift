/// Modifier keys relevant to terminal keyboard copy-mode command resolution.
public struct TerminalKeyboardCopyModeModifiers: OptionSet, Equatable, Sendable {
    /// The raw option-set storage.
    public let rawValue: UInt8

    /// Creates a modifier set from raw option bits.
    ///
    /// - Parameter rawValue: The raw option-set storage.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The Command modifier.
    public static let command = TerminalKeyboardCopyModeModifiers(rawValue: 1 << 0)

    /// The Shift modifier.
    public static let shift = TerminalKeyboardCopyModeModifiers(rawValue: 1 << 1)

    /// The Control modifier.
    public static let control = TerminalKeyboardCopyModeModifiers(rawValue: 1 << 2)

    /// The numeric-pad modifier, ignored during command matching.
    public static let numericPad = TerminalKeyboardCopyModeModifiers(rawValue: 1 << 3)

    /// The function-key modifier, ignored during command matching.
    public static let function = TerminalKeyboardCopyModeModifiers(rawValue: 1 << 4)

    /// The Caps Lock modifier, ignored during command matching.
    public static let capsLock = TerminalKeyboardCopyModeModifiers(rawValue: 1 << 5)
}
