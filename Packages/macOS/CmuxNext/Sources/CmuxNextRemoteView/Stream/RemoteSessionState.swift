import Foundation

/// Where a session is in its life, as the host and transport report it.
public nonisolated enum RemoteSessionState: Sendable, Hashable {
    case connecting
    /// The host asked a person there to allow the session.
    case waitingForConsent
    case streaming
    case ended(RemoteSessionEnd)
}

/// Why a session ended. The pane keeps the last frame and offers Reconnect.
public nonisolated enum RemoteSessionEnd: Sendable, Hashable {
    /// A person at the host (or its owner) ended this viewer's session.
    case disconnectedBy(name: String)
    /// The host turned remote desktop off.
    case hostStoppedSharing
    /// The viewer pressed Stop.
    case stoppedByViewer
    /// The path closed (timeout, network change the overlay could not move).
    case connectionLost
    /// The host refused, or nobody answered the consent prompt in time.
    case consentDenied
}
