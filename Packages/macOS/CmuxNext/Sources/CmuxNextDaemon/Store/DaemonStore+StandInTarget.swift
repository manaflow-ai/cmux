import Foundation

/// A pane a create is aimed at, named so it can be found once the daemon has it (#26695).
/// A create pressed on a stand-in (a pane an earlier Cmd-D or Cmd-N still shows provisionally) must
/// not send the stand-in's handle: it is client-only (``ProvisionalPane``), the daemon refuses it
/// (`unknown pane`), and the refusal took the create back: the pane showed, then vanished. Taken in
/// the press's turn (``DaemonStore/paneTarget(_:)``), while the stand-in's create is still known;
/// resolved later (``DaemonStore/daemonPane(confirming:)``), once the daemon's pane took it over.
public struct PaneTarget: Sendable, Hashable {
    enum Identity: Sendable, Hashable {
        /// A daemon pane: sent as is.
        case daemon
        /// A split's stand-in: the daemon's pane takes it over under this public pane id.
        case split(paneID: String)
        /// Cmd-N's first pane: the daemon's workspace under this key brings it.
        case workspace(WorkspaceKey)
        /// A stand-in whose create is no longer known: nothing will take it over.
        case gone
    }

    /// The handle the create was aimed at.
    public let handle: PaneID
    let identity: Identity
}

extension DaemonStore {
    struct StandInWaiter {
        let target: PaneTarget
        let resume: @MainActor (PaneID?) -> Void
    }

    /// `handle` named for a create: call it in the press's turn, before any await, while the
    /// stand-in's create is still in the log.
    public func paneTarget(_ handle: PaneID) -> PaneTarget {
        guard handle.rawValue >= ProvisionalPane.firstHandle else { return PaneTarget(handle: handle, identity: .daemon) }
        if let paneID = standInTargets[handle] ?? pane(handle)?.resourceID?.rawValue ?? splitPaneID(minting: handle) {
            return PaneTarget(handle: handle, identity: .split(paneID: paneID))
        }
        if let key = workspaceKey(minting: handle) { return PaneTarget(handle: handle, identity: .workspace(key)) }
        return PaneTarget(handle: handle, identity: .gone)
    }

    /// The daemon pane a create aimed at `target` names: its handle for a daemon pane; for a
    /// stand-in, the daemon's pane that took it over, once the records hold it (at once when they
    /// already do). Nil when the stand-in's create was refused, its pane is gone, or the connection
    /// ended first: there is no pane to aim at.
    public func daemonPane(confirming target: PaneTarget) async -> PaneID? {
        if case .daemon = target.identity { return target.handle }
        if let confirmed = confirmedHandle(target) { return confirmed }
        guard standInPending(target) else { return nil }
        return await withCheckedContinuation { (done: CheckedContinuation<PaneID?, Never>) in
            standInWaiters.append(StandInWaiter(target: target) { done.resume(returning: $0) })
        }
    }

    /// Runs the waiters whose stand-in the daemon took over or let go; every one with `all` (the
    /// connection is gone: no pane will come for its commands). Called once the visible state is
    /// complete again after an apply or an event batch (``withOverlayLifted(writer:snapshot:_:)``,
    /// ``flushAppliedWaiters()``).
    func runStandInWaiters(all: Bool = false) {
        guard !standInWaiters.isEmpty, applyDepth == 0, !overlayLifted else { return }
        var kept: [StandInWaiter] = [], due: [(StandInWaiter, PaneID?)] = []
        for waiter in standInWaiters {
            if let confirmed = confirmedHandle(waiter.target) {
                due.append((waiter, confirmed))
            } else if all || !standInPending(waiter.target) {
                due.append((waiter, nil))
            } else {
                kept.append(waiter)
            }
        }
        standInWaiters = kept
        for (waiter, pane) in due { waiter.resume(pane) }
    }

    /// The public pane id of the pending split that minted stand-in `handle`.
    private func splitPaneID(minting handle: PaneID) -> String? {
        intentLog.entries.lazy.compactMap { entry -> String? in
            if case .splitPane(_, _, _, let provisional) = entry.kind, provisional.handle == handle { return provisional.paneID }
            return nil
        }.first
    }

    /// The key of the pending Cmd-N whose first pane is stand-in `handle`.
    private func workspaceKey(minting handle: PaneID) -> WorkspaceKey? {
        intentLog.entries.lazy.compactMap { entry -> WorkspaceKey? in
            if case .createWorkspace(let provisional, _) = entry.kind, provisional.pane == handle { return provisional.key }
            return nil
        }.first
    }

    /// The daemon's pane that took the stand-in over, once the records hold it.
    private func confirmedHandle(_ target: PaneTarget) -> PaneID? {
        switch target.identity {
        case .daemon:
            return target.handle
        case .split(let paneID):
            return index.panesByResource[ResourceID(rawValue: paneID)].flatMap { $0.handle != target.handle ? $0.handle : nil }
        case .workspace(let key):
            // The daemon's new workspace has one pane, which holds its first tab.
            return workspacesByKey[key]?.screens.lazy.flatMap(\.panes)
                .first { $0.handle.rawValue < ProvisionalPane.firstHandle && !$0.tabs.isEmpty }?.handle
        case .gone:
            return nil
        }
    }

    /// Whether the stand-in's create may still bring its pane: the create that minted it is in the
    /// log (and not cancelled), or the records still show the stand-in.
    private func standInPending(_ target: PaneTarget) -> Bool {
        switch target.identity {
        case .daemon, .gone:
            return false
        case .split(let paneID):
            if pane(target.handle) != nil { return true }
            return intentLog.entries.contains { entry in
                guard !entry.closeWhenCreated, case .splitPane(_, _, _, let provisional) = entry.kind else { return false }
                return provisional.paneID == paneID
            }
        case .workspace(let key):
            return intentLog.entries.contains { entry in
                guard !entry.closeWhenCreated, case .createWorkspace(let provisional, _) = entry.kind else { return false }
                return provisional.key == key
            }
        }
    }
}
