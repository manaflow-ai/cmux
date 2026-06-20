import Foundation

actor RPCStackTokenGate {
    private var current: (id: UUID, task: Task<String, any Error>, waiters: Int, timedOut: Bool)?
    private let taskTimeout = RPCTaskTimeout()

    func token(
        timeoutNanoseconds: UInt64,
        provider: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        let id: UUID
        let task: Task<String, any Error>
        if let existing = current {
            guard !existing.timedOut else {
                throw MobileShellConnectionError.requestTimedOut
            }
            id = existing.id
            task = existing.task
            current?.waiters += 1
        } else {
            id = UUID()
            task = Task { try await provider() }
            current = (id: id, task: task, waiters: 1, timedOut: false)
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
        current = (id: id, task: task, waiters: 0, timedOut: true)
        task.cancel()
    }

    private func cancelWaiter(id: UUID) {
        guard current?.id == id, let task = current?.task else { return }
        current?.waiters -= 1
        guard let waiters = current?.waiters, waiters <= 0 else {
            return
        }
        current = nil
        task.cancel()
    }

    private func clear(id: UUID) {
        guard current?.id == id else { return }
        current = nil
    }
}
