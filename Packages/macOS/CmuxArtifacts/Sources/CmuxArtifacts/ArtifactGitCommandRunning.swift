import Foundation

/// Executes bounded Git privacy checks for an artifact repository.
protocol ArtifactGitCommandRunning: Sendable {
    /// Runs Git with bounded input and captures the output needed for exact validation.
    func run(
        arguments: [String],
        standardInput: Data?
    ) throws -> (terminationStatus: Int32, standardOutput: Data)
}
