/// The terminal outcome of Simulator text delivery.
public enum ControlSimulatorCompletion: Sendable, Equatable {
    /// The worker acknowledged the complete text payload.
    case succeeded
    /// The worker rejected or failed to deliver the text payload.
    case failed
}
