import Foundation

/// Failures specific to bounded artifact Git privacy subprocesses.
enum ArtifactGitCommandError: Error, Equatable, Sendable {
    /// The subprocess exceeded its configured execution deadline.
    case timedOut
}
