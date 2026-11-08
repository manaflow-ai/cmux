public import Foundation

/// The attachment state of a Simulator Web Inspector session.
public enum ControlSimulatorWebInspectorSessionSnapshot: Sendable, Equatable {
    /// No target is attached.
    case detached
    /// The named session is attached to the named target.
    case attached(sessionID: UUID, targetID: String)
}
