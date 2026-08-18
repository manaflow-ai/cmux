import Foundation

/// Resolves refs through the repository's configured reference-storage backend.
protocol GitReferenceReading: Sendable {
    func snapshot(repository: ResolvedGitRepository) -> GitReferenceSnapshot
}
