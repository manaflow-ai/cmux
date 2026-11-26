public import Foundation

/// The result of submitting a Web Inspector state mutation to the app.
public enum ControlSimulatorWebInspectorMutationResolution: Sendable, Equatable {
    /// The main actor accepted the operation; worker completion remains asynchronous.
    case accepted(surfaceID: UUID)
    /// The requested Simulator surface could not be resolved.
    case failed(ControlSimulatorTargetFailure)
    /// Native Web Inspector support is unavailable.
    case unavailable
    /// The requested target no longer exists.
    case targetNotFound(String)
    /// No Web Inspector target is attached.
    case sessionDetached
}
