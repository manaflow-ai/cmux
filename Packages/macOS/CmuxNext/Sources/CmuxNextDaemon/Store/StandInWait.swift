import class CmuxSafeConcurrency.OnceContinuation

/// A create waiting in ``DaemonStore/daemonTarget(_:)`` for the daemon's pane of a stand-in whose own create is in
/// flight. The store resumes it from the reconcile that resolves it (``DaemonStore/resolveStandInWaits()``): every
/// event, snapshot, settlement and rejection passes there, so no timer is needed, and the wait is bounded by the
/// stand-in's own create (its reply, its failure or its connection's end). A wait dropped unresumed throws
/// `OnceContinuationError.abandoned` instead of hanging its create.
struct StandInWait {
    /// Where a stand-in target stands.
    enum State: Equatable {
        /// The daemon's pane took the stand-in over.
        case adopted(PaneID)
        /// Its create is still in flight: the target is valid, the create waits.
        case opening
        /// Its create failed or was closed: the target was never made.
        case notCreated
    }

    let handle: PaneID
    let origin: StandInOrigin?
    let continuation: OnceContinuation<PaneID, any Error>

    /// Where stand-in `handle` (made by `origin`) stands in `store` now.
    @MainActor static func state(of handle: PaneID, origin: StandInOrigin?, in store: DaemonStore) -> State {
        guard let origin else { return .notCreated }
        if let pane = ProvisionalSplit.daemonPane(of: origin, showing: handle, in: store), pane.rawValue < ProvisionalPane.firstHandle {
            return .adopted(pane)
        }
        return ProvisionalSplit.createInFlight(origin, in: store) ? .opening : .notCreated
    }
}
