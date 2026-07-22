import Foundation

/// Executes bounded Git privacy checks for an artifact repository.
protocol ArtifactGitCommandRunning: Sendable {
    /// Runs Git with the supplied arguments and returns its termination status.
    func terminationStatus(arguments: [String]) throws -> Int32
}
