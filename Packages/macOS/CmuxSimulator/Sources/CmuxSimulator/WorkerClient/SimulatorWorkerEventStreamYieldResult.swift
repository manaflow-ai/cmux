/// Result of publishing an event to a bounded worker stream.
public enum SimulatorWorkerEventStreamYieldResult: Equatable, Sendable {
    /// The event was delivered or buffered.
    case enqueued
    /// The event exceeded the stream's byte or event ceiling.
    case overflow
    /// The stream had already terminated.
    case terminated
}
