import Foundation

/// Iterator for a single-consumer worker event stream.
public struct SimulatorWorkerEventStreamAsyncIterator: AsyncIteratorProtocol, Sendable {
    private let storage: SimulatorWorkerEventStreamStorage
    // Retaining the lifetime keeps the subscription registered while an
    // iterator outlives the stream value used to create it.
    private let lifetime: SimulatorWorkerEventStreamLifetime

    init(
        storage: SimulatorWorkerEventStreamStorage,
        lifetime: SimulatorWorkerEventStreamLifetime
    ) {
        self.storage = storage
        self.lifetime = lifetime
    }

    /// Returns the next event, or `nil` after cancellation or termination.
    public mutating func next() async -> SimulatorWorkerEvent? {
        if Task.isCancelled {
            await storage.finish()
            return nil
        }
        let identifier = UUID()
        let storage = self.storage
        return await withTaskCancellationHandler {
            await storage.next(identifier: identifier)
        } onCancel: {
            Task { await storage.cancelNext(identifier: identifier) }
        }
    }
}
