/// Why the tunnel refused a datagram or a handshake.
public enum WireGuardTunnelError: Error, Sendable, Hashable {
    case malformedMessage
    /// mac1 does not match this end's public key.
    case badMAC
    case decryptFailed
    /// The initiator's static key is not the expected peer.
    case unexpectedPeer
    /// The responder's authorizer refused the initiator's key.
    case unauthorized
    /// An initiation whose timestamp is not newer than the last accepted one.
    case replayedInitiation
    /// A data counter already seen or older than the replay window.
    case replayedCounter
    /// A response or data packet for no session of this tunnel.
    case unknownIndex
    /// The keypair is older than REJECT_AFTER_TIME or used too often.
    case sessionExpired
    /// The handshake did not complete within REKEY_ATTEMPT_TIME.
    case handshakeTimeout
}
