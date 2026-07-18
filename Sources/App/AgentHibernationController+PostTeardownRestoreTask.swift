import Foundation
import os

final class AgentHibernationRestoreMonitorStartGate: @unchecked Sendable {
    private struct State {
        var result: Bool?
        var continuation: CheckedContinuation<Bool, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait() async -> Bool {
        if Task.isCancelled { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate = state.withLock { state -> Bool? in
                    if let result = state.result { return result }
                    state.continuation = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            self.resolve(false)
        }
    }

    func resolve(_ result: Bool) {
        let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard state.result == nil else { return nil }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }
}

extension AgentHibernationController {
    struct PostTeardownRestoreTask {
        let requestID: UUID
        let cancellationState: PostTeardownRestoreCancellationState
        let task: Task<Void, Never>
    }
}
