import Foundation

/// Owns one replay request shared by attach and refresh, independently of either waiter.
@MainActor
final class HiveTerminalReplayCoordinator {
    private struct Request {
        let id: UUID
        let task: Task<Void, any Error>
    }

    private var request: Request?
    var isRunning: Bool { request != nil }

    /// A new subscription waits for an older replay, then obtains a snapshot
    /// requested after that subscription existed so intervening deltas cannot vanish.
    func run(
        afterCurrent: Bool,
        operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        if afterCurrent, let current = request {
            // The previous subscription's failure is not this subscription's
            // failure. Its fresh request still gets an independent attempt.
            _ = await current.task.result
            try Task.checkCancellation()
        }
        let active: Request
        if let current = request {
            active = current
        } else {
            let id = UUID()
            let task = Task { [weak self] in
                defer { self?.finish(id: id) }
                try Task.checkCancellation()
                try await operation()
                try Task.checkCancellation()
            }
            active = Request(id: id, task: task)
            request = active
        }
        try await active.task.value
        try Task.checkCancellation()
    }

    func cancel() {
        let current = request
        request = nil
        current?.task.cancel()
    }

    private func finish(id: UUID) {
        guard request?.id == id else { return }
        request = nil
    }
}
