/// Retains stream storage and closes the subscription when released.
final class SimulatorWorkerEventStreamLifetime: Sendable {
    private let storage: SimulatorWorkerEventStreamStorage

    init(storage: SimulatorWorkerEventStreamStorage) {
        self.storage = storage
    }

    deinit {
        let storage = self.storage
        Task { await storage.finish() }
    }
}
