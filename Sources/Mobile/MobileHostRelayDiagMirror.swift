/// Mirror of the relay policy most recently installed by the account
/// pipeline, for the `iroh_diag` socket verb. Like
/// `MobileHostIrohRuntime.hostDiagnosticLog`, it is readable without a
/// main-actor hop so the verb keeps working when the main thread is wedged.
/// Writes are ordered by a main-actor revision because separate `Task` hops
/// from the writer funnel are not guaranteed to arrive in submission order.
actor MobileHostRelayDiagMirror {
    private var revision: UInt64 = 0
    private var state: MobileHostIrohRuntime.RelayDiagState?

    func apply(
        revision newRevision: UInt64,
        state newState: MobileHostIrohRuntime.RelayDiagState?
    ) {
        guard newRevision > revision else { return }
        revision = newRevision
        state = newState
    }

    func current() -> MobileHostIrohRuntime.RelayDiagState? {
        state
    }
}
