import Foundation

/// The canonical Codex session represented by one of a process's open rollouts.
struct CodexRolloutIdentity: Equatable, Sendable {
    let sessionID: String
    let transcriptPath: String
}
