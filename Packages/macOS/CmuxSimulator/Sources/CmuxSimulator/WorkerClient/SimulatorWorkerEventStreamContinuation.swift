/// Producer handle for a bounded worker event stream.
public final class SimulatorWorkerEventStreamContinuation: Sendable {
    private let storage: SimulatorWorkerEventStreamStorage

    init(storage: SimulatorWorkerEventStreamStorage) {
        self.storage = storage
    }

    /// Delivers or buffers one event while enforcing the configured ceilings.
    public func yield(
        _ event: SimulatorWorkerEvent,
        byteCount: Int = 1
    ) async -> SimulatorWorkerEventStreamYieldResult {
        await storage.yield(event, byteCount: byteCount)
    }

    /// Finishes the stream and resumes a suspended consumer with `nil`.
    public func finish() async {
        await storage.finish()
    }
}
