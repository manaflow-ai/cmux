/// Outcome of one connect attempt performed by the owner's dialer closure.
public enum ConnectAttemptResult: Sendable {
    case admitted(any PeerConnection, sessionID: String)
    case denied(DenialCode)
}
