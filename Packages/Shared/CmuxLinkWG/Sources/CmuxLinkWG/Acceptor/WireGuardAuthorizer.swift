/// The host's paired-device trust store (B6), asked once per handshake
/// initiation from a key. Nil refuses: the host sends nothing back.
public protocol WireGuardAuthorizer: Sendable {
    func authorize(peer: WireGuardPublicKey) async -> WireGuardAuthorizedPeer?
}
