import Foundation

/// A local patch applied at intent time, before the daemon confirms it.
/// Patches must be idempotent: after a snapshot they are reapplied until the
/// daemon echoes their transaction, and the snapshot may already include them.
public enum OptimisticPatch: Sendable {
    case moveTab(surface: SurfaceID, toPane: PaneID, index: Int)
    case setTabPinned(surface: SurfaceID, pinned: Bool)
    case renameTab(surface: SurfaceID, name: String?)
    case renameWorkspace(key: WorkspaceKey, name: String)
    case moveWorkspace(key: WorkspaceKey, index: Int)
    case setWorkspaceGroup(key: WorkspaceKey, group: WorkspaceGroupID?)
    case setWorkspaceGroupCollapsed(WorkspaceGroupID, collapsed: Bool)
    case setTabGroupCollapsed(TabGroupID, collapsed: Bool)
    case custom(@MainActor @Sendable (DaemonStore) -> Void)
}

struct PendingPatch {
    let transaction: ClientTransactionID
    let patch: OptimisticPatch
    /// The command succeeded on a daemon that will not echo: drop at the next
    /// snapshot instead of reapplying.
    var dropAtNextSnapshot = false
}

extension DaemonStore {
    /// Applies `patch`, sends the command with a fresh transaction id, and
    /// settles the patch: dropped on the echo, or reverted (via resync) when
    /// the command fails. Set `expectEcho` false for commands whose daemon
    /// does not echo `transaction`; the patch then lasts until the next snapshot.
    public func perform(
        _ patch: OptimisticPatch,
        expectEcho: Bool = true,
        _ send: @Sendable (ClientTransactionID) async throws -> Void
    ) async throws {
        let transaction = ClientTransactionID.generate()
        applyOptimistic(patch, transaction: transaction)
        do {
            try await send(transaction)
            if !expectEcho { settleOptimistic(transaction) }
        } catch {
            rejectOptimistic(transaction)
            throw error
        }
    }

    public func applyOptimistic(_ patch: OptimisticPatch, transaction: ClientTransactionID) {
        pendingPatches.append(PendingPatch(transaction: transaction, patch: patch))
        apply(patch)
        workspaceListMayHaveChanged()
    }

    /// The command failed: drop the patch and restore daemon truth.
    public func rejectOptimistic(_ transaction: ClientTransactionID) {
        guard pendingPatches.contains(where: { $0.transaction == transaction }) else { return }
        pendingPatches.removeAll { $0.transaction == transaction }
        resync()
    }

    /// The command succeeded but no echo will come.
    public func settleOptimistic(_ transaction: ClientTransactionID) {
        guard let index = pendingPatches.firstIndex(where: { $0.transaction == transaction }) else { return }
        pendingPatches[index].dropAtNextSnapshot = true
    }

    public var hasPendingPatches: Bool { !pendingPatches.isEmpty }

    /// The daemon echoed `transaction`: record it and drop its patch.
    func confirm(_ transaction: ClientTransactionID) {
        pendingPatches.removeAll { $0.transaction == transaction }
        guard !confirmedTransactions.contains(transaction) else { return }
        confirmedTransactions.append(transaction)
        if confirmedTransactions.count > transactionLimit {
            confirmedTransactions.removeFirst(confirmedTransactions.count - transactionLimit)
        }
        onTransactionConfirmed?(transaction)
    }

    func reapplyPendingPatches() {
        pendingPatches.removeAll { $0.dropAtNextSnapshot }
        for pending in pendingPatches { apply(pending.patch) }
    }

    private func apply(_ patch: OptimisticPatch) {
        switch patch {
        case .moveTab(let surface, let toPane, let index):
            guard let target = panesByHandle[toPane], let source = pane(containing: surface) else { return }
            if source === target, target.tabs.firstIndex(where: { $0.surface == surface }) == min(index, target.tabs.count - 1) { return }
            guard let tab = source.removeTab(surface: surface) else { return }
            target.insertTab(tab, at: index)
            structureChanged()
        case .setTabPinned(let surface, let pinned):
            tabsBySurface[surface]?.setPinned(pinned)
        case .renameTab(let surface, let name):
            tabsBySurface[surface]?.setName(name)
        case .renameWorkspace(let key, let name):
            workspacesByKey[key]?.setName(name)
        case .moveWorkspace(let key, let index):
            guard let from = workspaces.firstIndex(where: { $0.key == key }) else { return }
            let clamped = min(max(index, 0), workspaces.count - 1)
            guard clamped != from else { return }
            let model = workspaces.remove(at: from)
            workspaces.insert(model, at: clamped)
            recomputeSidebar()
        case .setWorkspaceGroup(let key, let group):
            workspacesByKey[key]?.setGroup(group)
            recomputeSidebar()
        case .setWorkspaceGroupCollapsed(let id, let collapsed):
            groups.first { $0.id == id }?.setCollapsed(collapsed)
        case .setTabGroupCollapsed(let id, let collapsed):
            tabGroupsByID[id]?.setCollapsed(collapsed)
        case .custom(let body):
            body(self)
        }
    }
}
