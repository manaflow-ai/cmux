/// The current state of an isolated Simulator worker session.
public enum SimulatorSessionStatus: Codable, Equatable, Sendable {
    /// No device has been selected.
    case idle
    /// The child worker is starting and resolving Xcode frameworks.
    case connecting
    /// The worker is attached and presenting live frames.
    case streaming
    /// The selected device is installed but is not booted.
    case deviceUnavailable
    /// The child exited unexpectedly while cmux remained alive.
    case workerCrashed
    /// The worker rejected the session with a recoverable or terminal failure.
    case failed(SimulatorFailure)
}
