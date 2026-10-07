/// An initiation this end sent and awaits a response to.
struct WireGuardInitiation {
    let localIndex: UInt32
    let chainKey: [UInt8]
    let hash: [UInt8]
    let ephemeral: WireGuardPrivateKey
    let sentAt: Duration
    let message: [UInt8]
}
