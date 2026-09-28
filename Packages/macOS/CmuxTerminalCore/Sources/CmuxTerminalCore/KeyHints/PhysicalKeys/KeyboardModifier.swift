/// A modifier as the app sees it, whichever side of the keyboard sent it.
public enum KeyboardModifier: Sendable, Hashable, CaseIterable {
    case control
    case option
    case shift
    case command

    /// The modifier's glyph: `⌃`, `⌥`, `⇧`, `⌘`.
    public var glyph: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }

    /// The left-hand key for this modifier.
    public var leftKey: PhysicalKey {
        switch self {
        case .control: .leftControl
        case .option: .leftOption
        case .shift: .leftShift
        case .command: .leftCommand
        }
    }

    /// The right-hand key for this modifier.
    public var rightKey: PhysicalKey {
        switch self {
        case .control: .rightControl
        case .option: .rightOption
        case .shift: .rightShift
        case .command: .rightCommand
        }
    }
}
