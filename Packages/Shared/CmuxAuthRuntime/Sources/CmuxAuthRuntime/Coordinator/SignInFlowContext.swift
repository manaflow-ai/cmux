/// Staleness context captured before a sign-in flow can suspend.
struct SignInFlowContext {
    let generation: UInt64
    let attempt: UInt64
    let signOutEpoch: UInt64
}
