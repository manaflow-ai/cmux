import Foundation

extension BrowserDesignModeController {
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
            await previousLease.artifactStore.releaseHandoff(previousLease.id)
        }
        return operation == operationRevision
    }
}
