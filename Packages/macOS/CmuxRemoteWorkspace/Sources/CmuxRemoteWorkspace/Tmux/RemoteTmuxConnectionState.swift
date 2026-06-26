public enum RemoteTmuxConnectionState: Sendable, Equatable {
    /// The initial connection is being established before the first control-mode
    /// `%enter`.
    case connecting

    /// Live: control mode is up and streaming.
    case connected

    /// The transport dropped; retrying with backoff while the mirror stays frozen.
    case reconnecting

    /// Permanently over: genuine `%exit`, session gone, or deliberate stop.
    case ended
}
