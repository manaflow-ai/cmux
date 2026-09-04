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

    /// Returns a snapshot and, when requested, backend paths for watcher setup.
    func snapshot(
        repository: ResolvedGitRepository,
        deadline: DispatchTime?,
        includeStorageWatchPaths: Bool
    ) -> GitReferenceSnapshot

    /// Revalidates the checked-out reference after a concurrent index read.
    /// File-backed implementations may use their bounded direct path.
    func headSnapshot(
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

    func snapshot(
        repository: ResolvedGitRepository,
        deadline: DispatchTime?,
        includeStorageWatchPaths _: Bool
    ) -> GitReferenceSnapshot {
        snapshot(repository: repository, deadline: deadline)
    }

    func headSnapshot(
        repository: ResolvedGitRepository,
        deadline: DispatchTime?
    ) -> GitReferenceSnapshot {
        snapshot(repository: repository, deadline: deadline)
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
