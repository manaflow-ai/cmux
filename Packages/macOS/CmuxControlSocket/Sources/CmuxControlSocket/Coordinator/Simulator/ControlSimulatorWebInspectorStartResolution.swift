public import Foundation

/// The synchronous result of asking the app to start a Web Inspector operation.
public enum ControlSimulatorWebInspectorStartResolution: Sendable {
    /// The operation started and will resolve the supplied receipt within its contract timeout.
    case started(
        surfaceID: UUID,
        timeoutSeconds: TimeInterval,
        receipt: ControlSimulatorWebInspectorReceipt
    )
    /// The requested Simulator surface could not be resolved.
    case failed(ControlSimulatorTargetFailure)
    /// Native Web Inspector support is unavailable.
    case unavailable
    /// The requested target no longer exists.
    case targetNotFound(String)
    /// No Web Inspector target is attached.
    case sessionDetached
}
