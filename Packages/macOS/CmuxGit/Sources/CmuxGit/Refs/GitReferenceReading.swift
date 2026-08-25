import Dispatch
import Foundation

/// Resolves refs through the repository's configured reference-storage backend.
nonisolated protocol GitReferenceReading: Sendable {
    /// Returns one consistent view of the repository's checked-out ref.
    func snapshot(repository: ResolvedGitRepository) -> GitReferenceSnapshot

    /// Returns a snapshot without starting work after the supplied deadline.
    func snapshot(
        repository: ResolvedGitRepository,
        deadline: DispatchTime?
    ) -> GitReferenceSnapshot

    /// Reports whether resolving this repository requires storage-independent Git plumbing.
    func requiresGitPlumbing(repository: ResolvedGitRepository) -> Bool

    /// Reports whether plumbing is needed without waiting past the supplied deadline.
    func requiresGitPlumbing(
        repository: ResolvedGitRepository,
        deadline: DispatchTime?
    ) -> Bool
}

extension GitReferenceReading {
    func snapshot(
        repository: ResolvedGitRepository,
        deadline _: DispatchTime?
    ) -> GitReferenceSnapshot {
        snapshot(repository: repository)
    }

    /// File-backed test readers may use the direct parser by default.
    func requiresGitPlumbing(repository: ResolvedGitRepository) -> Bool {
        false
    }

    func requiresGitPlumbing(
        repository: ResolvedGitRepository,
        deadline _: DispatchTime?
    ) -> Bool {
        requiresGitPlumbing(repository: repository)
    }
}
