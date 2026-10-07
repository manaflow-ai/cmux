/// One set of transport keys from a completed handshake.
struct WireGuardKeypair {
    let localIndex: UInt32
    let remoteIndex: UInt32
    let sendKey: WireGuardAEAD
    let receiveKey: WireGuardAEAD
    /// This end sent the initiation that made the keypair (it rekeys).
    let isInitiator: Bool
    let createdAt: Duration
    var sendCounter: UInt64 = 0
    var replay = ReplayWindow()

    func isUsable(at now: Duration, timers: WireGuardTimers) -> Bool {
        now - createdAt < timers.rejectAfterTime && sendCounter < timers.rejectAfterMessages
    }
}
