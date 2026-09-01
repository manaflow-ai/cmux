/// Identifies the local endpoint used by a manual-IO relay.
public enum TuiManualIORelayTarget: Equatable, Sendable {
    /// Resolve a named local cmux-tui session.
    case session(String)
    /// Connect to an explicit local Unix socket.
    case socket(String)
}
