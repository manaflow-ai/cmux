public import Foundation

/// The synchronous result of asking the app to start a native Simulator operation.
public enum ControlSimulatorOperationStartResolution: Sendable {
    /// The operation started and will resolve the supplied receipt within its contract timeout.
    case started(surfaceID: UUID, timeoutSeconds: TimeInterval, receipt: ControlSimulatorOperationReceipt)
    /// The requested Simulator surface could not be resolved.
    case failed(ControlSimulatorTargetFailure)
    /// The resolved Simulator does not support the requested operation.
    case unavailable(String)
    /// The operation parameters are invalid for the resolved Simulator.
    case invalid(String)
}
