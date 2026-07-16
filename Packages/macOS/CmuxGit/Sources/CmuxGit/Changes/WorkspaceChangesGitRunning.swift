import Foundation

/// The subprocess seam used by ``WorkspaceChangesService``.
protocol WorkspaceChangesGitRunning: Sendable {
    func run(arguments: [String], in directory: URL) throws -> WorkspaceChangesGitResult
}
