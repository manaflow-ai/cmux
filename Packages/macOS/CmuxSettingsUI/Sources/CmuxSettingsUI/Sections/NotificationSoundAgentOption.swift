import Foundation

/// One host-provided agent-registry row in the notification sound matrix.
nonisolated public struct NotificationSoundAgentOption: Equatable, Identifiable, Sendable {
    /// The stable agent-registry identifier persisted as a matrix key.
    public let id: String
    /// The user-facing agent name shown in Settings.
    public let displayName: String

    /// Creates a matrix row from an agent-registry entry.
    ///
    /// - Parameters:
    ///   - id: The stable agent-registry identifier.
    ///   - displayName: The user-facing agent name.
    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}
