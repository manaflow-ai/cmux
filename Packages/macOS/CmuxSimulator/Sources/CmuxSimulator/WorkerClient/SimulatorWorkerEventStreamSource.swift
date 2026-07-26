/// Owns the consumer and producer endpoints of one bounded worker event stream.
public struct SimulatorWorkerEventStreamSource: Sendable {
    /// Consumer endpoint.
    public let stream: SimulatorWorkerEventStream
    /// Producer endpoint.
    public let continuation: SimulatorWorkerEventStream.Continuation

    /// Creates a bounded stream source.
    /// - Parameters:
    ///   - maximumBufferedBytes: Maximum total byte charge retained for a slow consumer.
    ///   - maximumBufferedEvents: Maximum number of retained events.
    ///   - onTermination: Called once after cancellation or explicit finish.
    public init(
        maximumBufferedBytes: Int,
        maximumBufferedEvents: Int,
        onTermination: @escaping @Sendable () -> Void
    ) {
        let storage = SimulatorWorkerEventStreamStorage(
            maximumBufferedBytes: maximumBufferedBytes,
            maximumBufferedEvents: maximumBufferedEvents,
            onTermination: onTermination
        )
        let lifetime = SimulatorWorkerEventStreamLifetime(storage: storage)
        stream = SimulatorWorkerEventStream(storage: storage, lifetime: lifetime)
        continuation = SimulatorWorkerEventStreamContinuation(storage: storage)
    }
}
