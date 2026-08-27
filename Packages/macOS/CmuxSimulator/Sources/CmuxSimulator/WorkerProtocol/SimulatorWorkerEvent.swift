/// A host-side event delivered to each Simulator worker subscriber.
public enum SimulatorWorkerEvent: Equatable, Sendable {
    /// The worker emitted a protocol message.
    case message(SimulatorWorkerOutbound)
    /// The worker process exited or its protocol pipe closed.
    case workerStopped
}
