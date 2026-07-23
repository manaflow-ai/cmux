import Foundation

/// Executes bounded Git privacy checks for an artifact repository.
protocol ArtifactGitCommandRunning: Sendable {
    /// Runs Git while discarding output and returns only its termination status.
    func terminationStatus(arguments: [String]) async throws -> Int32

    /// Runs Git with bounded input and captures the output needed for exact validation.
    func run(
        arguments: [String],
        standardInput: Data?
    ) async throws -> (terminationStatus: Int32, standardOutput: Data)
}
