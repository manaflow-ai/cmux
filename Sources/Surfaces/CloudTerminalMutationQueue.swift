import Foundation

/// Serializes one machine's terminal mutations across actor suspension points.
///
/// The daemon revision covers the whole machine, including other workspaces.
/// Every create keeps its turn through snapshot, mutation, and receipt handling.
@MainActor
final class CloudTerminalMutationQueue {
    private var tail: Task<Void, Never>?
    private var tailID: UUID?
    private var cancellations: [UUID: @Sendable () -> Void] = [:]

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
            let value = try await operation()
            try Task.checkCancellation()
            return value
        }
        cancellations[id] = { task.cancel() }
        tailID = id
        tail = Task { @MainActor [weak self] in
            _ = try? await task.value
            self?.cancellations[id] = nil
            if self?.tailID == id {
                self?.tail = nil
                self?.tailID = nil
            }
        }
        return task
    }

    /// Invalidates every admitted turn but retains their ordering until active work drains.
    func cancelAll() {
        for cancel in cancellations.values { cancel() }
    }

    /// Teardown joins cancelled work before another provider may use this machine's transport.
    func waitForIdle() async {
        await tail?.value
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
