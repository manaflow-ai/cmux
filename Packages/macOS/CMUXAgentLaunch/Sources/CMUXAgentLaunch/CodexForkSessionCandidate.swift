import Foundation

/// A Codex rollout candidate correlated to the parent fork session.
public struct CodexForkSessionCandidate: Equatable, Sendable {
    /// The child session identifier recorded in the rollout metadata.
    public let sessionID: String
    /// The parent session identifier recorded in the rollout metadata.
    public let parentSessionID: String
    /// The rollout file path associated with this candidate.
    public let transcriptPath: String
    /// The rollout metadata timestamp or bounded filesystem timestamp.
    public let createdAt: Date

    /// Creates a rollout candidate for fork correlation.
    public init(
        sessionID: String,
        parentSessionID: String,
        transcriptPath: String,
        createdAt: Date
    ) {
        self.sessionID = sessionID
        self.parentSessionID = parentSessionID
        self.transcriptPath = transcriptPath
        self.createdAt = createdAt
    }
}
