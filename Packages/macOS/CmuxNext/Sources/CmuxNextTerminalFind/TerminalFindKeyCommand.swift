/// A key the find bar's field handles itself while it has the keyboard.
///
/// The field is a text input, so app shortcuts do not reach the registry
/// while it is focused (input-spec K3); the bar maps these keys directly.
public enum TerminalFindKeyCommand: Sendable, Equatable {
    case next
    case previous
    case close

    /// Modifier keys held with a key, independent of AppKit.
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// Return finds the next match and Shift-Return the previous one,
    /// Cmd-G the next and Shift-Cmd-G (or Option-Cmd-G, Find Previous's
    /// menu shortcut) the previous one, and Escape closes the bar.
    ///
    /// - Parameter key: The key's characters ignoring modifiers: `"\r"`
    ///   for Return (`"\u{3}"` for keypad Enter), `"\u{1b}"` for Escape,
    ///   else the character.
    /// - Parameter modifiers: The modifier keys held with it.
    public init?(key: String, modifiers: Modifiers) {
        switch key.lowercased() {
        case "\r", "\u{3}":
            if modifiers.isEmpty {
                self = .next
            } else if modifiers == .shift {
                self = .previous
            } else {
                return nil
            }
        case "g":
            if modifiers == .command {
                self = .next
            } else if modifiers == [.command, .shift] || modifiers == [.command, .option] {
                self = .previous
            } else {
                return nil
            }
        case "\u{1b}":
            guard modifiers.isEmpty else { return nil }
            self = .close
        default:
            return nil
        }
    }
}
