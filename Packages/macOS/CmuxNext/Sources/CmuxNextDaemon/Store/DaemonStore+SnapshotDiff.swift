import Foundation

/// A snapshot apply that costs what changed (plans/cmux-next/main-thread-budget.md): every
/// `tree-changed` refetches the whole tree, and applying it re-applied, re-indexed and re-laid every
/// record of the session on the main thread (the sweep: newWindow stalled 243 ms, workspace.duplicate
/// timed out at STRESS). Now only the workspaces that differ from the last applied snapshot, or that
/// an event changed since, are touched; the rest keep their records as they are.
extension DaemonStore {
    /// The identities to apply from `tree` when the memo can vouch for the rest, else nil (apply in
    /// full): no live snapshot of this connection yet, a launch snapshot shown, another daemon
    /// generation or registry, or a confirmed write since that named no workspace.
    func incrementalChanges(_ tree: DaemonTree, diff: SnapshotDiff?) -> Set<String>? {
        let memo = snapshotMemo
        guard !isProvisional, !memo.untracked, memo.epoch == connectionEpoch, !memo.applied.isEmpty,
              memo.generation == tree.generation, memo.registryID == tree.registryID else { return nil }
        let changed = diff.flatMap { $0.revision == memo.revision ? $0.changed : nil }
            ?? SnapshotDiff.compute(tree, against: memo.applied, revision: memo.revision).changed
        // An event applied while the diff ran is in `dirty` too: its workspace takes the snapshot's
        // state, which is at least as new (events at or below the snapshot's barrier are superseded;
        // newer ones wait in the held inbox and apply after it).
        return changed.union(memo.dirty)
    }

    /// `applyTree` for the workspaces in `touched` only, then their index entries, primes and state;
    /// removed workspaces leave the index; the order is the snapshot's. The sidebar flattens again
    /// only when the order, the membership or a group changed.
    func applyTreeIncrementally(_ tree: DaemonTree, touching touched: Set<String>) {
        directories.follow(tree.generation)
        if workspaceRevision != tree.workspaceRevision { workspaceRevision = tree.workspaceRevision }
        if let reordered = reconcile(groups, with: tree.groups, id: \.id, make: WorkspaceGroupModel.init, update: { $0.update($1) }) {
            groups = reordered
            sidebarNeedsRecompute = true
        }
        applyPersonal(tree.personal)
        if let reordered = reconcile(savedTabGroups, with: tree.savedTabGroups, id: \.id, make: SavedTabGroupModel.init,
                                     update: { $0.update($1) }) {
            savedTabGroups = reordered
        }
        savedOpenGroups = Set(savedTabGroups.compactMap(\.openGroup))
        // The confirmed records by identity, as the full reconcile matches them (the overlay is lifted).
        var existing: [String: WorkspaceModel] = [:]
        existing.reserveCapacity(workspaces.count)
        for model in workspaces { existing[model.id] = model }
        var next: [WorkspaceModel] = []
        next.reserveCapacity(tree.workspaces.count)
        var reindex: [WorkspaceModel] = []
        for snapshot in tree.workspaces {
            let id = WorkspaceModel.identity(snapshot)
            if let model = existing.removeValue(forKey: id) {
                if touched.contains(id) {
                    let group = model.group
                    model.update(snapshot)
                    if model.group != group { sidebarNeedsRecompute = true }
                    reindex.append(model)
                }
                next.append(model)
            } else {
                let model = confirmedWorkspace(snapshot)
                next.append(model)
                reindex.append(model)
                sidebarNeedsRecompute = true
            }
        }
        for model in existing.values {
            index.remove(model)
            sidebarNeedsRecompute = true
        }
        if next.count != workspaces.count || zip(next, workspaces).contains(where: { $0 !== $1 }) {
            workspaces = next
            index.noteTabOrderChanged()
            sidebarNeedsRecompute = true
        }
        for model in reindex { indexed(model) }
        // A changed workspace may have reordered its tabs (the full path notes it for every snapshot).
        if !reindex.isEmpty { index.noteTabOrderChanged() }
    }

    /// Records `tree` as the last applied live snapshot (the next one diffs against it).
    func recordSnapshotMemo(_ tree: DaemonTree) {
        var applied: [String: WorkspaceSnapshot] = snapshotMemo.applied
        if snapshotMemo.epoch != connectionEpoch || snapshotMemo.untracked || applied.isEmpty {
            applied = Dictionary(tree.workspaces.map { (WorkspaceModel.identity($0), $0) }, uniquingKeysWith: { _, new in new })
        } else {
            var present = Set<String>()
            present.reserveCapacity(tree.workspaces.count)
            for snapshot in tree.workspaces {
                let id = WorkspaceModel.identity(snapshot)
                present.insert(id)
                if applied[id] != snapshot { applied[id] = snapshot }
            }
            if present.count != applied.count { applied = applied.filter { present.contains($0.key) } }
        }
        snapshotMemo = SnapshotMemo(applied: applied, epoch: connectionEpoch, generation: tree.generation, registryID: tree.registryID,
                                    revision: snapshotMemo.revision &+ 1)
    }

    /// Before `event` applies to the confirmed records: the workspaces it changes are marked, so
    /// the next snapshot applies them even when the daemon's copy did not change; an event whose
    /// workspace cannot be named makes the next snapshot apply in full.
    func noteSnapshotTouch(_ event: DaemonEvent) {
        guard !snapshotMemo.applied.isEmpty, !snapshotMemo.untracked else { return }
        switch event {
        case .workspaceAdded(let delta), .workspaceClosed(let delta), .workspaceRenamed(let delta), .workspaceMoved(let delta),
             .workspaceChanged(let delta):
            snapshotMemo.dirty.insert(WorkspaceModel.identity(delta.entity))
        case .screenAdded(let delta), .screenClosed(let delta), .screenRenamed(let delta), .screenChanged(let delta):
            markSnapshotTouch(workspace: delta.workspace)
        case .paneAdded(let delta), .paneClosed(let delta):
            markSnapshotTouch(workspace: delta.workspace)
        case .tabAdded(let delta), .tabClosed(let delta), .tabRenamed(let delta), .tabChanged(let delta):
            markSnapshotTouch(workspace: delta.workspace)
            markSnapshotTouch(surface: delta.surface)
        case .layoutChanged(let screen, _, _):
            if let found = index.screensByHandle[screen], let workspace = index.workspace(holding: found) {
                snapshotMemo.dirty.insert(workspace.id)
            } else {
                snapshotMemo.untracked = true
            }
        case .titleChanged(let surface, _), .surfaceResized(let surface, _), .surfaceExited(let surface):
            markSnapshotTouch(surface: surface)
        case .agentChanged(let status):
            markSnapshotTouch(surface: status.surface)
        case .agentPresenceChanged(let presence):
            markSnapshotTouch(surface: presence.surface)
        case .notification(let notification):
            if let surface = notification.surface { markSnapshotTouch(surface: surface) }
        case .overflow:
            // Presence cleared on every tab, and the events it stands for named nothing.
            snapshotMemo.untracked = true
        case .connected, .disconnected, .daemonShutdown, .treeChanged, .personalChanged, .sessionState, .scrollChanged, .bell,
             .frontendProjectionChanged, .terminalRegistryChanged, .bookmarksChanged, .historyChanged, .keybindingsChanged,
             .conversationChanged, .conversationTyping, .conversationDraft, .conversationLive, .conversationRunChanged,
             .cloudConversations, .terminalClipboardRead, .terminalClipboardReadCancelled, .client, .unknown:
            // No confirmed tree record changes (a resync, a connection change, side state).
            break
        }
    }

    private func markSnapshotTouch(workspace handle: WorkspaceHandle) {
        if let workspace = index.workspacesByHandle[handle] {
            snapshotMemo.dirty.insert(workspace.id)
        } else {
            snapshotMemo.untracked = true
        }
    }

    /// The workspace holding `surface` now; a surface the store does not show changes nothing.
    private func markSnapshotTouch(surface: SurfaceID) {
        guard let tab = index.tabsBySurface[surface], let pane = index.pane(holding: tab), let screen = index.screen(holding: pane),
              let workspace = index.workspace(holding: screen) else { return }
        snapshotMemo.dirty.insert(workspace.id)
    }
}
