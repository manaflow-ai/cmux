import Foundation

/// High-level relay connection state.
public enum CollaborationConnectionState: Equatable, Sendable {
    /// The session has not connected to a relay.
    case idle
    /// The client is connected to the relay.
    case connected
    /// The relay is unavailable at session start.
    case relayUnavailable
    /// The relay disconnected after a session had started.
    case disconnected
    /// The client reconnected and is resynchronizing documents.
    case resynchronizing
}
