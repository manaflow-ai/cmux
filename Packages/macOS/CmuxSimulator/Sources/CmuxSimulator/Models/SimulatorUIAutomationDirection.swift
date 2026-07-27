/// A semantic direction used by swipe and drag actions.
public enum SimulatorUIAutomationDirection: String, Codable, Equatable, Sendable {
    /// Moves from lower content toward upper content.
    case up
    /// Moves from upper content toward lower content.
    case down
    /// Moves from right content toward left content.
    case left
    /// Moves from left content toward right content.
    case right
}
