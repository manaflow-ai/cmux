import Foundation

extension GitMetadataService {
    /// Resolves refs on the package's bounded blocking-I/O lane.
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
