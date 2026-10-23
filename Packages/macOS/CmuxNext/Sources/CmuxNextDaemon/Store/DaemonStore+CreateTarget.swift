import Foundation

/// Where a create pressed on a pane goes now (``DaemonStore/createTarget(for:)``).
enum CreateTarget: Equatable {
    /// The daemon's pane to name.
    case pane(PaneID)
    /// A stand-in whose create is still in flight and has no daemon pane yet: wait.
    case pending
    /// Nothing to name: an unknown stand-in.
    case gone
}

// The send-time target of every key-turn create (Cmd-D, Cmd-Shift-D, New Column, New Row, a new
// terminal tab, a chat's split): a create pressed on a pending create's stand-in waits for that
// stand-in's daemon pane, and one whose stand-in's create was cancelled or refused goes to that
// create's own anchor, as its overlay shows it. A stand-in's handle never reaches the daemon.
extension DaemonStore {
    /// Records a split intent's stand-in (its public id, anchor and create) as it enters the log.
    func noteStandIn(_ intent: Intent, transaction: ClientTransactionID) {
        guard case .splitPane(let target, _, _, let provisional) = intent else { return }
        standIns[provisional.handle] = StandInPane(paneID: provisional.paneID, anchor: target, transaction: transaction)
    }

    /// Where a create pressed on `handle` goes now: a daemon pane is itself; a stand-in is the
    /// daemon's pane that took it over, its anchor's target once its create was cancelled or
    /// refused, or pending while its create is in flight with no daemon pane yet.
    func createTarget(for handle: PaneID) -> CreateTarget {
        var handle = handle
        var seen: Set<PaneID> = []
        while handle.rawValue >= ProvisionalPane.firstHandle {
            guard seen.insert(handle).inserted, let standIn = standIns[handle] else { return .gone }
            // A cancelled create's daemon pane closes as soon as it is known: never build on it.
            if intentLog.wasCancelled(standIn.transaction) {
                handle = standIn.anchor
                continue
            }
            if let pane = index.panesByResource[ResourceID(rawValue: standIn.paneID)], pane.handle != handle {
                return .pane(pane.handle)
            }
            if intentLog.contains(standIn.transaction) { return .pending }
            // Refused, or made and closed again before anything named it.
            handle = standIn.anchor
        }
        return .pane(handle)
    }

    /// The daemon pane a create pressed on `handle` must name, at send time: `handle` itself for a
    /// daemon pane; for a pending create's stand-in, the daemon's pane once the store holds it
    /// (this waits for its `pane-added`, not for its reply), or its anchor's once its create was
    /// cancelled or refused.
    ///
    /// Call it right before the send, on the main actor: when the target is known it returns
    /// without suspending, so creates keep the order they were pressed in.
    ///
    /// - Throws: ``CreateTargetGone`` when `handle` is a stand-in the store no longer knows.
    public func daemonTarget(for handle: PaneID) async throws -> PaneID {
        // wakeup-allow: each pass waits for the next store lift (an event), never polls.
        while true {
            switch createTarget(for: handle) {
            case .pane(let pane):
                return pane
            case .gone:
                throw CreateTargetGone(pane: handle)
            case .pending:
                await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in standInWaiters.append(resume) }
            }
        }
    }

    /// Every lift can give a stand-in its daemon pane, cancel it or refuse it: the waiting creates
    /// look again (each one waits again while its stand-in is still pending).
    func resumeStandInWaiters() {
        guard !standInWaiters.isEmpty else { return }
        let waiters = standInWaiters
        standInWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// A stand-in stays known while a pending intent shows it, names it as its pane, or can fall
    /// back through it (the anchors of the kept ones, transitively).
    func releaseStandIns() {
        guard !standIns.isEmpty else { return }
        var kept: Set<PaneID> = []
        for entry in intentLog.entries {
            switch entry.kind {
            case .splitPane(let target, _, _, let provisional):
                kept.insert(target)
                kept.insert(provisional.handle)
            case .createTab(let pane, _):
                kept.insert(pane)
            default:
                break
            }
        }
        var open = Array(kept)
        while let next = open.popLast() {
            if let anchor = standIns[next]?.anchor, kept.insert(anchor).inserted { open.append(anchor) }
        }
        standIns = standIns.filter { kept.contains($0.key) }
    }
}
