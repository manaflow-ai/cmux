import CmuxMobileShell
import Foundation

/// Stateless RPC adapter used by the native tree and web patch stream.
struct MobileDiffRPCService: Sendable {
    let client: any MobileSyncing
    let workspaceID: String

    func loadStatus() async throws -> MobileDiffStatusSnapshot {
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.workspace.git.status",
            params: ["workspace_id": workspaceID, "baseline": "worktree"]
        )
        let data = try await client.sendRequest(request, timeoutNanoseconds: nil)
        return try MobileDiffStatusSnapshot(MobileSyncGitStatusResponse.decode(data))
    }

    func patchStream(paths: [String]) -> AsyncThrowingStream<MobileDiffPatchChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let planner = MobileDiffBatchPlanner()
                    for batch in planner.initialBatches(paths: paths) {
                        try Task.checkCancellation()
                        let response = try await loadDiff(paths: batch)
                        continuation.yield(Self.chunk(response))

                        let retries = planner.truncatedRetryBatches(
                            truncated: response.truncated,
                            requestedOrder: batch
                        )
                        for retry in retries {
                            try Task.checkCancellation()
                            let retryResponse = try await loadDiff(paths: retry)
                            continuation.yield(Self.chunk(retryResponse))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func disconnect() async {
        await client.disconnect()
    }

    private func loadDiff(paths: [String]) async throws -> MobileSyncGitDiffResponse {
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.workspace.git.diff",
            params: ["workspace_id": workspaceID, "baseline": "worktree", "paths": paths]
        )
        let data = try await client.sendRequest(request, timeoutNanoseconds: nil)
        return try MobileSyncGitDiffResponse.decode(data)
    }

    private static func chunk(_ response: MobileSyncGitDiffResponse) -> MobileDiffPatchChunk {
        var patch = response.patch
        if !patch.isEmpty, !patch.hasSuffix("\n") {
            patch.append("\n")
        }
        return MobileDiffPatchChunk(
            data: Data(patch.utf8),
            tooLargePaths: response.tooLarge.map(\.path)
        )
    }
}
