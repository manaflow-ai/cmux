import Foundation

/// Owns diff-request replacement and serialization for one mobile connection.
/// The newest request cancels older work, then waits for it to stop before
/// starting, so abandoned phone requests cannot fan out concurrent Git jobs.
actor MobileWorkspaceDiffRequestCoordinator {
    private var latestRequestID: UUID?
    private var activeRequest: MobileWorkspaceDiffActiveRequest?

    func perform(
        _ operation: @escaping @Sendable () async -> MobileHostRPCResult
    ) async -> MobileHostRPCResult {
        let requestID = UUID()
        latestRequestID = requestID
        let previous = activeRequest?.task
        previous?.cancel()
        if let previous {
            _ = await previous.value
        }
        guard latestRequestID == requestID, !Task.isCancelled else {
            return Self.cancelledResult
        }

        let task = Task { await operation() }
        activeRequest = MobileWorkspaceDiffActiveRequest(id: requestID, task: task)
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if activeRequest?.id == requestID {
            activeRequest = nil
        }
        return result
    }

    private static var cancelledResult: MobileHostRPCResult {
        .failure(MobileHostRPCError(code: "cancelled", message: "Superseded by a newer diff request"))
    }
}
