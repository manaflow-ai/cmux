import Foundation

/// Where a session is in its life, as the host and transport report it.
public nonisolated enum RemoteSessionState: Sendable, Hashable {
    case connecting
    /// The host asked a person there to allow the session.
    case waitingForConsent
    case streaming
    case ended(RemoteSessionEnd)
}

/// Why a session ended. The pane keeps the last frame; a lost path reconnects by itself, and an
/// end someone chose (Stop, the host's) offers Reconnect.
public nonisolated enum RemoteSessionEnd: Sendable, Hashable {
    /// A person at the host (or its owner) ended this viewer's session.
    case disconnectedBy(name: String)
    /// The host turned remote desktop off.
    case hostStoppedSharing
    /// The host could not serve the session (its cmux.rd/1 `ended` said `failed: <reason>`:
    /// capture, encoder or display trouble on that machine); `reason` is the host's own words.
    case hostFailed(reason: String)
    /// The viewer pressed Stop.
    case stoppedByViewer
    /// The path closed (timeout, network change the overlay could not move).
    case connectionLost
    /// The host refused, or nobody answered the consent prompt in time.
    case consentDenied
    /// The host needs its own sign-in (an RFB compatibility host's user name
    /// and password). `rejected`: the ones sent were not accepted.
    case signInRequired(rejected: Bool)
}
