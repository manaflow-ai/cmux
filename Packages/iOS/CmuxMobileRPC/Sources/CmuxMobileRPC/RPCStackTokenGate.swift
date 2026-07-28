import Foundation

/// Deduplicates Stack access-token acquisition across mobile RPC clients owned by the same shell.
public actor RPCStackTokenGate {
    private var current: (id: UUID, task: Task<String, any Error>, waiters: Int, timedOutUntil: UInt64?)?
    private var abandoned: [UUID: Task<String, any Error>] = [:]
    private let taskTimeout = RPCTaskTimeout()
    private let timedOutResetNanoseconds: UInt64

    /// Creates a gate that suppresses retries after every waiter times out or cancels.
    public init(timedOutResetNanoseconds: UInt64 = 30_000_000_000) {
        self.timedOutResetNanoseconds = timedOutResetNanoseconds
    }

    func token(
        timeoutNanoseconds: UInt64,
        provider: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        let id: UUID
        let task: Task<String, any Error>
        if let existing = current, let timedOutUntil = existing.timedOutUntil {
            guard DispatchTime.now().uptimeNanoseconds >= timedOutUntil else {
                throw MobileShellConnectionError.requestTimedOut
            }
            guard abandoned.isEmpty else {
                throw MobileShellConnectionError.requestTimedOut
            }
            abandoned[existing.id] = existing.task
            current = nil
        }
        if let existing = current {
            id = existing.id
            task = existing.task
            current?.waiters += 1
        } else {
            id = UUID()
            task = Task { try await provider() }
            current = (id: id, task: task, waiters: 1, timedOutUntil: nil)
            Task.detached { [weak self] in
                _ = await task.result
                await self?.clear(id: id)
            }
        }

        do {
            let token = try await taskTimeout.value(task, timeoutNanoseconds: timeoutNanoseconds)
            clear(id: id)
            return token
        } catch MobileShellConnectionError.requestTimedOut {
            timeoutWaiter(id: id)
            throw MobileShellConnectionError.requestTimedOut
        } catch is CancellationError {
            cancelWaiter(id: id)
            throw CancellationError()
        } catch {
            clear(id: id)
            throw error
        }
    }

    private func timeoutWaiter(id: UUID) {
        guard current?.id == id, let task = current?.task else { return }
        current?.waiters -= 1
        guard let waiters = current?.waiters, waiters <= 0 else {
            return
        }
        current = (
            id: id,
            task: task,
            waiters: 0,
            timedOutUntil: DispatchTime.now().uptimeNanoseconds &+ timedOutResetNanoseconds
        )
        task.cancel()
    }

    private func cancelWaiter(id: UUID) {
        guard current?.id == id, let task = current?.task else { return }
        current?.waiters -= 1
        guard let waiters = current?.waiters, waiters <= 0 else {
            return
        }
        current = (
            id: id,
            task: task,
            waiters: 0,
            timedOutUntil: DispatchTime.now().uptimeNanoseconds &+ timedOutResetNanoseconds
        )
        task.cancel()
    }

    private func clear(id: UUID) {
        if current?.id == id {
            current = nil
        }
        abandoned[id] = nil
    }
}
