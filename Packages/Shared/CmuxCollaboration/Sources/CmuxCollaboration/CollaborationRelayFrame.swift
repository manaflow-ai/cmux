import Foundation

/// Client-side relay frame representation used by tests and transports.
public enum CollaborationRelayFrame: Codable, Equatable, Sendable {
    /// A CRDT update for a document.
    case documentUpdate(documentID: String, updateID: String, operations: [TextOperation])
    /// A full CRDT snapshot for a document.
    case documentSnapshot(documentID: String, requestID: String?, operations: [TextOperation], textHash: String)
    /// A request for any peer to send a full CRDT snapshot.
    case documentSnapshotRequest(documentID: String, requestID: String)
    /// Ephemeral peer presence.
    case presence(PresenceState)
    /// A peer disconnected or timed out.
    case peerLeft(peerID: String)
}
