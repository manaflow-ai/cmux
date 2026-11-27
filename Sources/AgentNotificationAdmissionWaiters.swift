import Foundation
import os

/// Synchronous cancellation/stream-termination callbacks share this short,
/// memory-only critical section; continuations always resume outside its lock.
final class AgentNotificationAdmissionWaiters: Sendable {
    private struct State: Sendable {
        var waiting: [UUID: CheckedContinuation<Bool, Never>] = [:]
        var cancelled: Set<UUID> = []
        var finished = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    @discardableResult
    func register(_ id: UUID, continuation: CheckedContinuation<Bool, Never>) -> Bool {
        let registered = state.withLock { state in
            guard !state.finished, !state.cancelled.contains(id) else { return false }
            state.waiting[id] = continuation
            return true
        }
        if !registered { continuation.resume(returning: false) }
        return registered
    }

    func contains(_ id: UUID) -> Bool { state.withLock { $0.waiting[id] != nil } }

    func complete(_ id: UUID?, accepted: Bool) {
        guard let id else { return }
        let continuation = state.withLock { $0.waiting.removeValue(forKey: id) }
        continuation?.resume(returning: accepted)
    }

    func cancel(_ id: UUID) {
        let continuation = state.withLock { state in
            state.cancelled.insert(id)
            return state.waiting.removeValue(forKey: id)
        }
        continuation?.resume(returning: false)
    }

    func forget(_ id: UUID) {
        _ = state.withLock { $0.cancelled.remove(id) }
    }

    func finish() {
        let pending = state.withLock { state in
            state.finished = true
            let values = Array(state.waiting.values)
            state.waiting.removeAll()
            state.cancelled.removeAll()
            return values
        }
        for continuation in pending { continuation.resume(returning: false) }
    }
}
