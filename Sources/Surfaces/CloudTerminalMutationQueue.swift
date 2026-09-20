import Foundation

/// Serializes one machine's terminal mutations across actor suspension points.
///
/// The daemon revision covers the whole machine, including other workspaces.
/// Every create keeps its turn through snapshot, mutation, and receipt handling.
@MainActor
final class CloudTerminalMutationQueue {
    private var tail: Task<Void, Never>?
    private var tailID: UUID?

    /// Reserves an ordered turn synchronously, before the operation can suspend.
    /// A cancelled turn still waits for its predecessor before releasing successors.
    func enqueue<Value: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async throws -> Value
    ) -> Task<Value, Error> {
        let previous = tail
        let id = UUID()
        let task = Task { @MainActor in
            if let previous { await previous.value }
            try Task.checkCancellation()
            return try await operation()
        }
        tailID = id
        tail = Task { @MainActor [weak self] in
            _ = try? await task.value
            if self?.tailID == id {
                self?.tail = nil
                self?.tailID = nil
            }
        }
        return task
    }

    /// Propagates caller cancellation without cancelling another intent's turn.
    func run<Value: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let task = enqueue(operation)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
