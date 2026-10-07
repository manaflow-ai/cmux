import CmuxMobileWire

/// An op sent and not yet decided; resent with the same key after a reconnect.
struct PendingOp {
    let frame: OpFrame
    let continuation: CheckedContinuation<OpOutcome, any Error>
}
