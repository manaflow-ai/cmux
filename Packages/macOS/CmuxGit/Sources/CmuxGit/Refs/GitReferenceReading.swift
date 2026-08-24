import Foundation

/// Resolves refs through the repository's configured reference-storage backend.
nonisolated protocol GitReferenceReading: Sendable {
    /// Returns one consistent view of the repository's checked-out ref.
    func snapshot(repository: ResolvedGitRepository) -> GitReferenceSnapshot

    /// Reports whether resolving this repository requires storage-independent Git plumbing.
    func requiresGitPlumbing(repository: ResolvedGitRepository) -> Bool
}

extension GitReferenceReading {
    /// File-backed test readers may use the direct parser by default.
    func requiresGitPlumbing(repository: ResolvedGitRepository) -> Bool {
        false
    }
}
