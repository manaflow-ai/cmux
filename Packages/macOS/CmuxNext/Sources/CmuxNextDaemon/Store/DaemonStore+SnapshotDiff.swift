import Foundation

/// A snapshot apply that costs what changed (plans/cmux-next/main-thread-budget.md): every
/// `tree-changed` refetches the whole tree, and applying it re-applied, re-indexed and re-laid every
/// record of the session on the main thread (the sweep: newWindow stalled 243 ms, workspace.duplicate
/// timed out at STRESS). Now only the workspaces that differ from the last applied snapshot, or that
/// an event changed since, are touched; the rest keep their records as they are.
extension DaemonStore {
    /// `tree` compared with the memo off the main thread; nil without a memo. Holds no reference
    /// to the memo's dictionary once it returns, so the apply after it updates the memo in place.
    func snapshotDiff(of tree: DaemonTree) async -> SnapshotDiff? {
        guard !snapshotMemo.applied.isEmpty else { return nil }
        return await SnapshotDiff.computed(tree, against: snapshotMemo.applied, revision: snapshotMemo.revision)
    }

    /// What differs between `tree` and the last applied live snapshot when the memo can vouch for
    /// the rest, else nil (apply in full): no live snapshot of this connection yet, a launch
    /// snapshot shown, another daemon generation or registry, or a confirmed write since that named
    /// no workspace. `diff` is used when it was computed against the current memo; otherwise the
    /// comparison runs here.
    func incrementalDiff(_ tree: DaemonTree, diff: SnapshotDiff?) -> SnapshotDiff? {
        guard !isProvisional, !snapshotMemo.untracked, snapshotMemo.epoch == connectionEpoch, !snapshotMemo.applied.isEmpty,
              snapshotMemo.generation == tree.generation, snapshotMemo.registryID == tree.registryID else { return nil }
        if let diff, diff.revision == snapshotMemo.revision { return diff }
        snapshotWorkspacesWalkedOnMain &+= tree.workspaces.count
        return SnapshotDiff.compute(tree, against: snapshotMemo.applied, revision: snapshotMemo.revision)
    }

    /// The workspaces an incremental apply touches: the ones `diff` names, and the ones an event
    /// changed since the last snapshot. An event applied while the diff ran is in `dirty` too: its
    /// workspace takes the snapshot's state, which is at least as new (events at or below the
    /// snapshot's barrier are superseded; newer ones wait in the held inbox and apply after it).
    func touchedWorkspaces(_ diff: SnapshotDiff) -> Set<String> {
        snapshotMemo.dirty.union(diff.changed.keys)
    }

    /// `applyTree` for the workspaces in `touched` only, then their index entries, primes and state;
    /// removed workspaces leave the index; the order is the snapshot's. The sidebar flattens again
    /// only when the order, the membership or a group changed.
    func applyTreeIncrementally(_ tree: DaemonTree, touching touched: Set<String>) {
        directories.follow(tree.generation)
        if workspaceRevision != tree.workspaceRevision { workspaceRevision = tree.workspaceRevision }
        // The sidebar's sections follow the groups' order (their `index`), which an in-place update can change.
        let groupOrder = groups.map { ($0.id, $0.index) }
        if let reordered = reconcile(groups, with: tree.groups, id: \.id, make: WorkspaceGroupModel.init, update: { $0.update($1) }) {
            groups = reordered
        }
        if groups.count != groupOrder.count || zip(groups, groupOrder).contains(where: { $0.id != $1.0 || $0.index != $1.1 }) {
            sidebarNeedsRecompute = true
        }
        applyPersonal(tree.personal)
        if let reordered = reconcile(savedTabGroups, with: tree.savedTabGroups, id: \.id, make: SavedTabGroupModel.init,
                                     update: { $0.update($1) }) {
            savedTabGroups = reordered
        }
        let wasSaved = savedOpenGroups
        savedOpenGroups = Set(savedTabGroups.compactMap(\.openGroup))
        // A group saved or unsaved in a workspace this snapshot does not touch: its live group learns
        // it here (the full path primes every pane; this one only the touched workspaces).
        for id in wasSaved.symmetricDifference(savedOpenGroups) {
            guard let group = index.tabGroupsByID[id] else { continue }
            let saved = savedOpenGroups.contains(id)
            if group.isSaved != saved { group.isSaved = saved }
        }
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
        reapplyEventWrittenTabs(skipping: touched)
        // A changed workspace may have reordered its tabs (the full path notes it for every snapshot).
        if !reindex.isEmpty { index.noteTabOrderChanged() }
    }

    /// The tabs a whole-value event (title, size, exit) wrote since the last snapshot, in the
    /// workspaces the apply did not touch: each takes its own snapshot, the memo's (which equals the
    /// new tree's for an untouched workspace), and only that tab is re-indexed and re-laid. Records
    /// that no longer hold the tab where the memo does (a change no event named) re-apply the
    /// workspace.
    private func reapplyEventWrittenTabs(skipping touched: Set<String>) {
        var reapplied = touched
        for surface in snapshotMemo.dirtyTabs {
            guard let tab = index.tabsBySurface[surface], let pane = index.pane(holding: tab), let screen = index.screen(holding: pane),
                  let workspace = index.workspace(holding: screen), !reapplied.contains(workspace.id),
                  let memoWorkspace = snapshotMemo.applied[workspace.id] else { continue }
            let paneSnapshot = memoWorkspace.screens.first(where: { $0.id == screen.handle })?.panes.first(where: { $0.id == pane.handle })
            if let snapshot = paneSnapshot?.tabs.first(where: { $0.surface == surface }) {
                tab.update(snapshot)
                indexed(tab, in: pane)
            } else {
                reapplied.insert(workspace.id)
                workspace.update(memoWorkspace)
                indexed(workspace)
                index.noteTabOrderChanged()
            }
        }
    }

    /// Records `tree`, applied in full, as the last applied live snapshot (the next one diffs
    /// against it). O(tree) on main, as the full apply itself is.
    func recordSnapshotMemo(_ tree: DaemonTree) {
        snapshotWorkspacesWalkedOnMain &+= tree.workspaces.count
        let applied = Dictionary(tree.workspaces.map { (WorkspaceModel.identity($0), $0) }, uniquingKeysWith: { _, new in new })
        snapshotMemo = SnapshotMemo(applied: applied, epoch: connectionEpoch, generation: tree.generation, registryID: tree.registryID,
                                    revision: snapshotMemo.revision &+ 1)
    }

    /// Records `tree`, applied incrementally, as the last applied live snapshot: the memo takes
    /// only `diff`'s entries (O(changed)); an unchanged workspace's entry equals its snapshot
    /// already. The memo's dictionary is moved out before it changes, so it is never copied.
    func advanceSnapshotMemo(_ tree: DaemonTree, applying diff: SnapshotDiff) {
        var applied: [String: WorkspaceSnapshot] = [:]
        swap(&applied, &snapshotMemo.applied)
        for (id, snapshot) in diff.changed { applied[id] = snapshot }
        for id in diff.removed { applied[id] = nil }
        snapshotMemo = SnapshotMemo(applied: applied, epoch: connectionEpoch, generation: tree.generation, registryID: tree.registryID,
                                    revision: snapshotMemo.revision &+ 1)
    }

    /// Before `event` applies to the confirmed records: what it changes of the tree snapshot is
    /// marked, so the next snapshot applies it even when the daemon's copy did not change: the
    /// workspace of a structural delta, the one tab of a whole-value tab event (title, size, exit).
    /// An event whose workspace cannot be named makes the next snapshot apply in full. Events that
    /// write no snapshot field mark nothing.
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
            // One tab's field: the next snapshot re-applies that tab, not its workspace.
            if index.tabsBySurface[surface] != nil { snapshotMemo.dirtyTabs.insert(surface) }
        case .agentChanged, .agentPresenceChanged, .notification:
            // Agent status and presence live beside the tree (the roster, TabModel.agent and presence)
            // and a notification in the store's list: no field of the tree snapshot changes.
            break
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
