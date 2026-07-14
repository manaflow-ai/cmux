import Foundation

/// The account-registry status of a live cmux session.
public enum CmxLiveSessionStatus: String, Codable, Sendable, Equatable {
    /// The agent is actively working.
    case working
    /// The agent is blocked until the user responds.
    case needsInput = "needs_input"
    /// The workspace is live and ready for input.
    case idle
    /// The most recent agent process ended, while its workspace remains attachable.
    case ended
}
