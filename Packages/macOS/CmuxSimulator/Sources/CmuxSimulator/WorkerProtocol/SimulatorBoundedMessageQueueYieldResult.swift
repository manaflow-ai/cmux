/// The result of attempting to enqueue one bounded worker-protocol message.
public enum SimulatorBoundedMessageQueueYieldResult: Equatable, Sendable {
    /// The message entered the queue.
    case enqueued
    /// The queue was full and rejected the message.
    case overflow
    /// The stream had already terminated.
    case terminated
}
