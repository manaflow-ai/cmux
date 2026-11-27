/// The result of reading cached Web Inspector state from the app.
public enum ControlSimulatorWebInspectorSnapshotResolution: Sendable, Equatable {
    /// Returns the current snapshot and whether a fresh asynchronous read was accepted.
    case snapshot(ControlSimulatorWebInspectorSnapshot, refreshAccepted: Bool)
    /// The requested Simulator surface could not be resolved.
    case failed(ControlSimulatorTargetFailure)
    /// Native Web Inspector support is unavailable.
    case unavailable
}
