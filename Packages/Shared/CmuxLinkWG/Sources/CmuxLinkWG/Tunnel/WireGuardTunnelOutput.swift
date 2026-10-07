/// What the tunnel wants done after an input: datagrams to put on the
/// underlay, a decrypted packet to deliver, and state changes.
struct WireGuardTunnelOutput {
    var datagrams: [[UInt8]] = []
    /// Decrypted plaintext (padded to 16 bytes). Empty for a keepalive.
    var plaintext: [UInt8]?
    /// This end completed a handshake as initiator, or a keypair it
    /// answered was confirmed by the initiator's first data packet.
    var sessionEstablished = false
    var error: WireGuardTunnelError?
}
