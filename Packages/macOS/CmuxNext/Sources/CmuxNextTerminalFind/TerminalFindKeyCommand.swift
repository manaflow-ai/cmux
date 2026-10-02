/// A key the find bar's field handles itself while it has the keyboard.
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

    /// Placeholder for the failing tests.
    public init?(key: String, modifiers: Modifiers) {
        return nil
    }
}
