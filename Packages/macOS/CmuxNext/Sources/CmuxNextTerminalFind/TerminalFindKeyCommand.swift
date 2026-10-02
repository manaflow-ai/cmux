/// A key the find bar's field handles itself while it has the keyboard.
///
/// The field is a text input, so app shortcuts do not reach the registry
/// while it is focused (input-spec K3); the bar maps these keys directly.
public enum TerminalFindKeyCommand: Sendable, Equatable {
    /// Select the next (older) match.
    case next
    /// Select the previous (newer) match.
    case previous
    /// Close the bar and return to the terminal.
    case close

    /// Modifier keys held with a key, independent of AppKit, so the key map
    /// is testable without events.
    public struct Modifiers: OptionSet, Sendable {
        /// The modifier bits.
        public let rawValue: Int
        /// - Parameter rawValue: The modifier bits.
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Shift.
        public static let shift = Modifiers(rawValue: 1 << 0)
        /// Control.
        public static let control = Modifiers(rawValue: 1 << 1)
        /// Option.
        public static let option = Modifiers(rawValue: 1 << 2)
        /// Command.
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
                // Shift-Cmd-G reaches the bar only when the user has rebound
                // Group Selected Workspaces, whose default it is (KeyRouter
                // takes navigation chords before a focused text field).
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
