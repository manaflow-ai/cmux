import CmuxMobileWire

/// An op sent and not yet decided; resent with the same key after a reconnect.
struct PendingOp {
    let frame: OpFrame
    let continuation: CheckedContinuation<OpOutcome, any Error>
    /// Sent again after a reconnect or `resendPending`: an offline refusal no longer proves it was not applied.
    var resent = false
}
