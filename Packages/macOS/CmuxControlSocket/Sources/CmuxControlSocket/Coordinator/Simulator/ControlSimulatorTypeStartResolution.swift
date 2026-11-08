public import Foundation

/// The synchronous result of asking the app to start Simulator text input.
public enum ControlSimulatorTypeStartResolution: Sendable {
    /// Text delivery started and will resolve the supplied receipt within its contract timeout.
    case started(
        surfaceID: UUID,
        characterCount: Int,
        completionTimeoutSeconds: TimeInterval,
        receipt: ControlSimulatorCompletionReceipt
    )
    /// The requested Simulator surface could not be resolved.
    case failed(ControlSimulatorTargetFailure)
    /// The text payload is empty.
    case emptyText
    /// The UTF-8 payload exceeds the reported byte limit.
    case textTooLong(maximumUTF8ByteCount: Int)
    /// The payload contains a scalar unsupported by Simulator keyboard input.
    case unsupportedCharacter(scalarIndex: Int, scalarValue: UInt32)
    /// The Simulator's keyboard input service is unavailable.
    case inputUnavailable
    /// The input request could not be delivered to the worker.
    case deliveryUnavailable
}
