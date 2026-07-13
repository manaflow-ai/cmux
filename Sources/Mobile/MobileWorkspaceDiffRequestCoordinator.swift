import Foundation

/// Owns diff-request replacement and serialization for one mobile connection.
/// The newest request cancels active work and replaces the single pending slot.
/// Superseded callers finish immediately, while at most one Git operation and
/// one pending request remain retained by the connection.
actor MobileWorkspaceDiffRequestCoordinator {
    private var activeRequest: MobileWorkspaceDiffActiveRequest?
    private var pendingRequest: MobileWorkspaceDiffPendingRequest?

    func perform(
        _ operation: @escaping @Sendable () async -> MobileHostRPCResult
    ) async -> MobileHostRPCResult {
        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(
                    MobileWorkspaceDiffPendingRequest(
                        id: requestID,
                        operation: operation,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { await self.cancel(requestID: requestID) }
        }
    }

    private func enqueue(_ request: MobileWorkspaceDiffPendingRequest) {
        guard activeRequest != nil else {
            start(request)
            return
        }
        if let pendingRequest {
            pendingRequest.continuation.resume(returning: Self.cancelledResult)
        }
        pendingRequest = request
        supersedeActiveRequest()
    }

    private func start(_ request: MobileWorkspaceDiffPendingRequest) {
        let task = Task { [weak self] in
            let result = await request.operation()
            await self?.finish(requestID: request.id, result: result)
        }
        activeRequest = MobileWorkspaceDiffActiveRequest(
            id: request.id,
            task: task,
            continuation: request.continuation,
            isSuperseded: false
        )
    }

    private func supersedeActiveRequest() {
        guard var activeRequest else { return }
        activeRequest.isSuperseded = true
        activeRequest.task.cancel()
        activeRequest.continuation?.resume(returning: Self.cancelledResult)
        activeRequest.continuation = nil
        self.activeRequest = activeRequest
    }

    private func cancel(requestID: UUID) {
        if pendingRequest?.id == requestID {
            let request = pendingRequest
            pendingRequest = nil
            request?.continuation.resume(returning: Self.cancelledResult)
        }
        if activeRequest?.id == requestID {
            supersedeActiveRequest()
        }
    }

    private func finish(requestID: UUID, result: MobileHostRPCResult) {
        guard let completed = activeRequest, completed.id == requestID else { return }
        activeRequest = nil
        if let continuation = completed.continuation {
            continuation.resume(
                returning: completed.isSuperseded ? Self.cancelledResult : result
            )
        }
        if let pendingRequest {
            self.pendingRequest = nil
            start(pendingRequest)
        }
    }

    private static var cancelledResult: MobileHostRPCResult {
        .failure(MobileHostRPCError(code: "cancelled", message: "Superseded by a newer diff request"))
    }
}
