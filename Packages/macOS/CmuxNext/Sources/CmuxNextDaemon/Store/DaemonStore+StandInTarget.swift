import Foundation

/// A create aimed at a stand-in pane (#26695): a second Cmd-D, New Tab page split or browser split
/// pressed on the pane an earlier create still shows provisionally. The stand-in's handle is
/// client-only (``ProvisionalPane``), so the daemon refuses it (`unknown pane`) and the refusal
/// took the second split back: the pane showed, then vanished. The create waits until the
/// daemon's pane takes the stand-in over under its public id, then names that pane.
extension DaemonStore {
    struct StandInWaiter {
        let standIn: PaneID
        let paneID: String
        let resume: @MainActor (PaneID?) -> Void
    }

    /// The daemon pane a create aimed at `handle` must name: `handle` itself for a daemon pane; for
    /// a stand-in, the daemon's pane that took it over, once the records hold it (at once when they
    /// already do). Nil when the stand-in's create was refused or its pane is gone, or the
    /// connection ended first: there is no pane to aim at.
    public func daemonPane(confirming handle: PaneID) async -> PaneID? {
        guard handle.rawValue >= ProvisionalPane.firstHandle else { return handle }
        guard let paneID = standInPaneID(handle) else { return nil }
        if let confirmed = confirmedHandle(paneID, standIn: handle) { return confirmed }
        guard standInPending(handle, paneID: paneID) else { return nil }
        return await withCheckedContinuation { (done: CheckedContinuation<PaneID?, Never>) in
            standInWaiters.append(StandInWaiter(standIn: handle, paneID: paneID) { done.resume(returning: $0) })
        }
    }

    /// Runs the waiters whose stand-in the daemon took over or let go; every one with `all` (the
    /// connection is gone: no pane will come for its commands). Called once the visible state is
    /// complete again after an apply (``withOverlayLifted(writer:snapshot:_:)``).
    func runStandInWaiters(all: Bool = false) {
        guard !standInWaiters.isEmpty, applyDepth == 0, !overlayLifted else { return }
        var due: [(StandInWaiter, PaneID?)] = []
        standInWaiters.removeAll { waiter in
            if let confirmed = confirmedHandle(waiter.paneID, standIn: waiter.standIn) {
                due.append((waiter, confirmed))
                return true
            }
            guard all || !standInPending(waiter.standIn, paneID: waiter.paneID) else { return false }
            due.append((waiter, nil))
            return true
        }
        for (waiter, pane) in due { waiter.resume(pane) }
    }

    /// The stand-in's public pane id: the one a pending create named it by, else its record's.
    private func standInPaneID(_ handle: PaneID) -> String? {
        if let paneID = standInTargets[handle] { return paneID }
        if let paneID = panesByHandle[handle]?.resourceID?.rawValue { return paneID }
        return intentLog.entries.lazy.compactMap { entry -> String? in
            if case .splitPane(_, _, _, let provisional) = entry.kind, provisional.handle == handle { return provisional.paneID }
            return nil
        }.first
    }

    /// The daemon's pane under the stand-in's public id, once the records hold it.
    private func confirmedHandle(_ paneID: String, standIn: PaneID) -> PaneID? {
        index.panesByResource[ResourceID(rawValue: paneID)].flatMap { $0.handle != standIn ? $0.handle : nil }
    }

    /// Whether the stand-in's create may still bring its pane: the split that minted it is in the
    /// log, or the records still show it (Cmd-N's first pane, whose workspace create is pending).
    private func standInPending(_ standIn: PaneID, paneID: String) -> Bool {
        if panesByHandle[standIn] != nil { return true }
        return intentLog.entries.contains { entry in
            guard !entry.closeWhenCreated, case .splitPane(_, _, _, let provisional) = entry.kind else { return false }
            return provisional.paneID == paneID
        }
    }
}
