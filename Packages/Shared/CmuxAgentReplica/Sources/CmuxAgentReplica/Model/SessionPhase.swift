import Foundation

/// Describes the current display phase of a session without monotonicity assumptions.
public enum SessionPhase: String, Codable, Hashable, Sendable {
    /// The session is starting.
    case starting
    /// The session is idle.
    case idle
    /// The session is actively working.
    case working
    /// The session needs user input.
    case needsInput
    /// The session has ended.
    case ended
    /// The session phase is unknown.
    case unknown
}
