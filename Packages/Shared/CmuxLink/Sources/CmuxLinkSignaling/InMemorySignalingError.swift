/// Errors of the in-memory relay, mirroring `signal.peer_offline`.
public enum InMemorySignalingError: Error, Sendable, Hashable {
    case peerOffline(String)
    /// The endpoint's queue is full (it stopped reading); the message is refused.
    case peerBusy(String)
}
