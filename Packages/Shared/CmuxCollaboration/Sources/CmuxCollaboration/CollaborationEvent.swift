import Foundation

/// Events emitted by a collaboration session.
public enum CollaborationEvent: Equatable, Sendable {
    /// A local or remote document changed.
    case documentChanged(CollaborationDocumentSnapshot)
    /// A peer's ephemeral presence changed.
    case presenceChanged(PresenceState)
    /// A peer left or timed out.
    case presenceCleared(peerID: String)
    /// The relay connection state changed.
    case connectionChanged(CollaborationConnectionState)
    /// Disk reconciliation produced a result for a file.
    case diskReconciled(DiskReconciliationResult)
}
