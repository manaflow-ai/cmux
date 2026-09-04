import Foundation

/// The semantic alert classes that may select an agent-specific sound.
///
/// Agent ids come from the host's registry and are stored as dynamic JSON
/// keys, so adding an agent never requires changing this settings package.
nonisolated public enum NotificationSoundAlertType: String, CaseIterable, Codable, Hashable, Sendable {
    /// A notification emitted after an agent finishes its turn.
    case turnDone
    /// A notification emitted when an agent is waiting for input or permission.
    case needsInput
    /// A notification emitted for an error or stalled agent.
    case errorStalled
}
