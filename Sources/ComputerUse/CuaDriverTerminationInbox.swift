import Foundation
import os

// Process callbacks and task cancellation race to resume one waiter; a tiny lock keeps that handoff synchronous.
final class CuaDriverTerminationInbox: @unchecked Sendable {
    private struct State {
        var bufferedStatus: Int32?
        var waiter: (id: UUID, continuation: CheckedContinuation<Int32?, Never>)?
    }

    private enum WaitRegistration {
        case waiting
        case resume(Int32?)
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func yield(_ status: Int32) {
        let continuation = state.withLock { state -> CheckedContinuation<Int32?, Never>? in
            guard let waiter = state.waiter else {
                state.bufferedStatus = status
                return nil
            }
            state.waiter = nil
            return waiter.continuation
        }
        continuation?.resume(returning: status)
    }

    func next() async throws -> Int32 {
        let id = UUID()
        let status: Int32? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
                let registration = state.withLock { state -> WaitRegistration in
                    if let status = state.bufferedStatus {
                        state.bufferedStatus = nil
                        return .resume(status)
                    }
                    if Task.isCancelled {
                        return .resume(nil)
                    }
                    precondition(state.waiter == nil)
                    state.waiter = (id, continuation)
                    return .waiting
                }
                if case .resume(let status) = registration {
                    continuation.resume(returning: status)
                }
            }
        } onCancel: {
            let continuation = self.state.withLock { state -> CheckedContinuation<Int32?, Never>? in
                guard state.waiter?.id == id else { return nil }
                let continuation = state.waiter?.continuation
                state.waiter = nil
                return continuation
            }
            continuation?.resume(returning: nil)
        }
        guard let status else { throw CancellationError() }
        return status
    }
}
