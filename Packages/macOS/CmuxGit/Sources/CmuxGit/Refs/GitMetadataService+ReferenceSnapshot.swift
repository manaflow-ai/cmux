import Foundation

extension GitMetadataService {
    /// Resolves the full reference snapshot for watcher/config consumers.
    nonisolated func gitReferenceSnapshotForConfig(
        repository: ResolvedGitRepository
    ) async -> GitReferenceSnapshot {
        await gitReferenceSnapshot(repository: repository)
    }

    /// Resolves the branch context for config traversal on the blocking-I/O lane.
    nonisolated func gitReferenceBranchContext(
        repository: ResolvedGitRepository
    ) async -> GitConfigBranchContext {
        .resolved((await gitReferenceSnapshot(repository: repository)).branchName)
    }

    /// Resolves refs on the package's bounded blocking-I/O lane.
    ///
    /// - Parameter repository: The already-resolved repository to inspect.
    /// - Returns: A consistent branch, commit, and head-signature snapshot.
    @concurrent
    nonisolated func gitReferenceSnapshot(
        repository: ResolvedGitRepository
    ) async -> GitReferenceSnapshot {
        let cancellationSignal = WorkspaceChangesCancellationSignal()
        let referenceReader = referenceReader
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.blockingStatusQueue.async {
                    let snapshot = cancellationSignal.withCurrentBinding {
                        referenceReader.snapshot(repository: repository)
                    }
                    continuation.resume(returning: snapshot)
                }
            }
        } onCancel: {
            cancellationSignal.cancel()
        }
    }
}
