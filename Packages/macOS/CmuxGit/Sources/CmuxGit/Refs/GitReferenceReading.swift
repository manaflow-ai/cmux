import Foundation

/// Resolves refs through the repository's configured reference-storage backend.
protocol GitReferenceReading: Sendable {
    /// Returns one consistent view of the repository's checked-out ref.
    func snapshot(repository: ResolvedGitRepository) -> GitReferenceSnapshot
}
