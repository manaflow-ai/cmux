/// The signaling path a WebRTC underlay uses: B1's `signal` frames on the
/// host socket. Shared with B2 (V1) so both carriers signal the same way.
public protocol SignalingChannel: Sendable {
    func send(_ message: SignalingMessage) async throws
    /// Every signal addressed to this end, in arrival order.
    func messages() -> AsyncStream<SignalingMessage>
}
