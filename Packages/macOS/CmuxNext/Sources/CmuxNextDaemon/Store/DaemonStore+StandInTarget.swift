import Foundation

/// What made a stand-in pane, by which the daemon's pane that takes it over is found.
enum StandInOrigin: Hashable {
    /// A split's, New Column's or New Row's provisional pane: the daemon's pane carries its public pane id.
    case pane(String)
    /// Cmd-N's workspace's first pane: the daemon's workspace carries its key, and its pane that holds the
    /// first tab takes the stand-in over (under its own handle and model).
    case workspace(WorkspaceKey)
}

/// A create waiting in ``DaemonStore/daemonTarget(_:)`` for the daemon's pane of a stand-in whose own create is in
/// flight. The store resumes it from the reconcile that resolves it (``DaemonStore/resolveStandInWaits()``): every
/// event, snapshot, settlement and rejection passes there, so no timer is needed, and the wait is bounded by the
/// stand-in's own create (its reply, its failure or its connection's end).
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
    let continuation: CheckedContinuation<PaneID, any Error>

    /// Where stand-in `handle` (made by `origin`) stands in `store` now.
    @MainActor static func state(of handle: PaneID, origin: StandInOrigin?, in store: DaemonStore) -> State {
        guard let origin else { return .notCreated }
        if let pane = ProvisionalSplit.daemonPane(of: origin, showing: handle, in: store), pane.rawValue < ProvisionalPane.firstHandle {
            return .adopted(pane)
        }
        return ProvisionalSplit.createInFlight(origin, in: store) ? .opening : .notCreated
    }
}

extension DaemonStore {
    /// Waits until the daemon's pane takes stand-in `handle` over (``StandInWait``), off the caller's turn. A cancelled
    /// caller is resumed with the rest, when the stand-in's own create ends (that bounds the wait), and then stops.
    func waitForDaemonPane(of handle: PaneID, origin: StandInOrigin?) async throws -> PaneID {
        let pane = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PaneID, any Error>) in
            standInWaits.append(StandInWait(handle: handle, origin: origin, continuation: continuation))
        }
        try Task.checkCancellation()
        return pane
    }

    /// Resumes the creates whose stand-in the daemon's pane took over (in the order they were pressed) or whose
    /// stand-in's create ended without a pane; the rest keep waiting. Runs at the end of every reconcile.
    func resolveStandInWaits() {
        guard !standInWaits.isEmpty else { return }
        let waits = standInWaits
        standInWaits.removeAll()
        for wait in waits {
            switch StandInWait.state(of: wait.handle, origin: wait.origin, in: self) {
            case .opening: standInWaits.append(wait)
            case .adopted(let pane): wait.continuation.resume(returning: pane)
            case .notCreated: wait.continuation.resume(throwing: PendingPaneNotCreated())
            }
        }
    }

    /// An intent left the log: the workspace of a Cmd-N create that was not refused records the stand-in pane it took
    /// over and its first tab's daemon surface (``WorkspaceModel/tookOverStandIn``), for a create pressed on that
    /// stand-in that is sent after the hand-over (a window that still shows the stand-in for a frame).
    func noteIntentLeft(_ entry: PendingIntent, rejected: Bool) {
        guard !rejected, case .createWorkspace(let provisional, _) = entry.kind,
              let workspace = workspacesByKey[provisional.key], !workspace.isProvisional else { return }
        workspace.tookOverStandIn = (provisional.pane, entry.createdConfirmed ? entry.createdSurface : nil)
    }

    /// The Cmd-N workspace whose create succeeded and whose stand-in pane was `handle`. A walk of the workspaces, only
    /// for a stand-in handle no pending intent names (rare: a create sent after its stand-in's hand-over).
    func adoptedStandIn(_ handle: PaneID) -> WorkspaceKey? {
        workspaces.first { $0.tookOverStandIn?.pane == handle }?.key
    }
}
