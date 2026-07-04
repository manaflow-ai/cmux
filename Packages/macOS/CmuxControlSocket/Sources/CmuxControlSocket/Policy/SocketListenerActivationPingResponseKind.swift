/// A bounded, telemetry-safe classification of a control-socket `ping` probe response.
///
/// The raw probe response is socket-controlled text that can carry local filesystem
/// details or arbitrary bytes, so callers should log this coarse kind rather than
/// the response itself.
public enum SocketListenerActivationPingResponseKind: String, Sendable, CaseIterable {
    /// No line at all (`nil`) -- a refused, timed-out, or skipped probe.
    case missing

    /// A line that is empty after trimming whitespace.
    case empty

    /// The healthy `PONG` reply from a live listener.
    case pong

    /// The password-mode auth-required challenge; still proves the accept loop is alive and dispatching.
    case authChallenge = "auth_challenge"

    /// A non-empty line that matches none of the known live-listener replies.
    case unexpected
}
