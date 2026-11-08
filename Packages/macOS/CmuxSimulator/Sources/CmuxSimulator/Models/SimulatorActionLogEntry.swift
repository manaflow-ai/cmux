import Foundation

/// A bounded user-action or control-action record for the Simulator tools panel.
public struct SimulatorActionLogEntry: Codable, Equatable, Identifiable, Sendable {
    /// The event identifier.
    public let id: UUID
    /// The event timestamp.
    public let timestamp: Date
    /// A stable action name.
    public let action: String
    /// A concise human-readable summary.
    public let summary: String
    /// Whether the action completed successfully.
    public let succeeded: Bool?

    /// Creates an action-log entry.
    public init(id: UUID, timestamp: Date, action: String, summary: String, succeeded: Bool?) {
        self.id = id
        self.timestamp = timestamp
        self.action = action
        self.summary = summary
        self.succeeded = succeeded
    }
}
