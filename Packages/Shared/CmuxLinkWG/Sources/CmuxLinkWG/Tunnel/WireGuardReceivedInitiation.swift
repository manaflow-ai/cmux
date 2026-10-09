/// A peer's initiation that authenticated (mac1, static and timestamp
/// AEADs), before the responder decides to answer it.
public struct WireGuardReceivedInitiation: Sendable {
    /// The initiator's static key.
    public let peer: WireGuardPublicKey
    let remoteIndex: UInt32
    let remoteEphemeral: [UInt8]
    let chainKey: [UInt8]
    let hash: [UInt8]
    let timestamp: TAI64N
}
