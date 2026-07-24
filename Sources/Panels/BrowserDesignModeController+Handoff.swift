import Foundation

@MainActor
private enum BrowserDesignModeHandoffState {
    struct Lease {
        let artifactStore: BrowserDesignModeArtifactStore
        let artifactPaths: [String]
    }

    static var currentLease: Lease?
}

extension BrowserDesignModeController {
    func deliverHandoff(
        prompt: String,
        artifactPaths: [String],
        operation: UInt
    ) async throws -> Bool {
        guard await artifactStore.retainHandoffArtifacts(at: artifactPaths) else {
            throw BrowserDesignModeError.invalidRuntimeResponse
        }
        guard operation == operationRevision else {
            await artifactStore.releaseHandoff(artifactPaths)
            return false
        }
        guard clipboardWriter(prompt) else {
            await artifactStore.releaseHandoff(artifactPaths)
            throw BrowserScreenshotError.pasteboardWriteFailed
        }

        let previousLease = BrowserDesignModeHandoffState.currentLease
        BrowserDesignModeHandoffState.currentLease = .init(
            artifactStore: artifactStore,
            artifactPaths: artifactPaths
        )
        if let previousLease {
            let currentPaths = Set(artifactPaths)
            let supersededPaths = previousLease.artifactPaths.filter {
                !currentPaths.contains($0)
            }
            await previousLease.artifactStore.releaseHandoff(supersededPaths)
        }
        return operation == operationRevision
    }
}
