import Foundation

/// Lifecycle state for the worker-owned Web Inspector forwarding session.
public enum SimulatorWebInspectorSessionStatus: Codable, Equatable, Sendable {
    /// No Web Inspector page is attached.
    case detached
    /// A raw JSON stream is attached to one target.
    case attached(sessionID: UUID, targetID: String)
}
