import Foundation

/// The canonical Codex session represented by one of a process's open rollouts.
public struct CodexRolloutIdentity: Equatable, Sendable {
    public let sessionID: String
    public let transcriptPath: String

    public init(
        sessionID: String,
        transcriptPath: String
    ) {
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
    }
}
