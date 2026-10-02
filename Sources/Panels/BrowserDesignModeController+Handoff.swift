import Foundation

extension BrowserDesignModeController {
    func discardHandoffCandidate(
        lease: UUID,
        artifactURLs: [URL]
    ) async {
        await artifactStore.remove(artifactURLs)
        await artifactStore.releaseHandoff(lease)
    }

    /// Synchronously relinquishes panel ownership, then removes the lease
    /// markers asynchronously so panel teardown never waits on filesystem I/O.
    func releaseDeliveredHandoffForTeardown() {
        guard let deliveredHandoffLease else { return }
        self.deliveredHandoffLease = nil
        Task {
            await deliveredHandoffLease.artifactStore.releaseHandoff(
                deliveredHandoffLease.id
            )
        }
    }

    func deliverHandoff(
        prompt: String,
        artifactPaths: [String],
        operation: UInt,
        candidateLease: UUID? = nil
    ) async throws -> Bool {
        let lease: UUID
        if let candidateLease {
            lease = candidateLease
        } else {
            lease = await artifactStore.beginHandoff()
        }
        guard await artifactStore.retainHandoffArtifacts(at: artifactPaths, lease: lease) else {
            await artifactStore.releaseHandoff(lease)
            throw BrowserDesignModeError.invalidRuntimeResponse
        }
        guard operation == operationRevision else {
            await artifactStore.releaseHandoff(lease)
            return false
        }
        guard clipboardWriter(prompt) else {
            await artifactStore.releaseHandoff(lease)
            throw BrowserScreenshotError.pasteboardWriteFailed
        }

        let previousLease = deliveredHandoffLease
        deliveredHandoffLease = (
            artifactStore: artifactStore,
            id: lease
        )
        if let previousLease {
            Task {
                await previousLease.artifactStore.releaseHandoff(previousLease.id)
            }
        }
        // The clipboard now references this lease. Later UI invalidation must
        // not make the caller discard artifacts that were already delivered.
        return true
    }
}
