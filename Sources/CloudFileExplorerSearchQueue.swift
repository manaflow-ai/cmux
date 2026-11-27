import Foundation

/// One guest command remains active until its result arrives. Only the newest
/// pending query is retained; cancellation cannot turn into overlapping VM execs.
actor CloudFileExplorerSearchQueue {
    typealias Operation = @Sendable () async throws -> FileSearchSnapshot
    private var active: CloudFileExplorerSearchRequest?
    private var pending: CloudFileExplorerSearchRequest?

    func submit(_ operation: @escaping Operation) async throws -> FileSearchSnapshot {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: FileSearchSnapshot = try await withCheckedThrowingContinuation { continuation in
                // Register and observe cancellation without suspending between them.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending?.continuation?.resume(throwing: CancellationError())
                pending = CloudFileExplorerSearchRequest(id: id, operation: operation, continuation: continuation)
                startNext()
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        if pending?.id == id {
            let continuation = pending?.continuation
            pending = nil
            continuation?.resume(throwing: CancellationError())
        } else if active?.id == id {
            let continuation = active?.continuation
            active?.continuation = nil
            continuation?.resume(throwing: CancellationError())
        }
    }

    private func startNext() {
        guard active == nil, let next = pending else { return }
        pending = nil
        active = next
        // This task intentionally outlives cancellation of its UI caller: VM
        // exec has no cancel RPC. Holding the slot until completion bounds work.
        Task {
            let result: Result<FileSearchSnapshot, Error>
            do { result = .success(try await next.operation()) }
            catch { result = .failure(error) }
            finish(next.id, result: result)
        }
    }

    private func finish(_ id: UUID, result: Result<FileSearchSnapshot, Error>) {
        guard active?.id == id else { return }
        let continuation = active?.continuation
        active = nil
        continuation?.resume(with: result)
        startNext()
    }
}
