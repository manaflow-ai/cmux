import CmuxMobileWire
import Foundation

extension MobileLinkClient {
    /// Submits one idempotent mutation on the shared RPC channel. The host
    /// sends `result`/`reject` followed by `request-settled`; this returns as
    /// soon as the mutation outcome is known and leaves the settlement frame
    /// to the channel reader.
    public func submit(_ op: String, params: JSONValue, idempotencyKey: String) async throws -> MobileLinkOperationResult {
        let channel = try await rpcChannel()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingOperations[idempotencyKey] = continuation
                Task {
                    do {
                        try await channel.send(frame: .op(OpFrame(op: op, params: params,
                                                                  idempotencyKey: idempotencyKey)))
                    } catch {
                        await self.settleOperation(idempotencyKey, .failure(MobileLinkClientError.linkLost))
                    }
                }
            }
        } onCancel: {
            Task { await self.settleOperation(idempotencyKey, .failure(CancellationError())) }
        }
    }
}
