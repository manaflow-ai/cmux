import Foundation

/// Native activity of one exact agent session, independent of execution mode.
public enum CmuxSidebarAgentActivity: String, Codable, CaseIterable, Equatable, Sendable {
    /// No trustworthy activity transition is known.
    case unknown
    /// The agent is working on a turn.
    case working
    /// The agent completed its turn without pending work.
    case idle
    /// A specific permission, question, or plan review needs the user.
    case needsInput
    /// The agent explicitly reported readiness.
    case ready
    /// The agent explicitly reported a wait unrelated to user feedback.
    case waiting
    /// An explicit provider quota condition prevents progress.
    case quotaBlocked
    /// A structured native failure prevents progress.
    case failed
    /// The agent explicitly paused or was interrupted.
    case paused
    /// The exact session ended.
    case ended

    /// Decodes an additive future value conservatively as unknown.
    /// - Parameter decoder: The wire decoder.
    /// - Throws: A decoding error when the value is not a string.
    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}
