/// The signaling seam: the control plane's `signal` frames for one install
/// (b1-control-do.md section 5). Production uses `ControlPlaneSignaling`;
/// tests use `InMemorySignalingHub`.
public protocol SignalingChannel: Sendable {
    /// Sends one message; throws when the control plane is not connected
    /// (nothing queues).
    func send(_ message: SignalMessage) async throws
    /// Every signal relayed to this install. Read by exactly one consumer
    /// (a `SignalRouter`).
    var incoming: AsyncStream<SignalMessage> { get }
}
