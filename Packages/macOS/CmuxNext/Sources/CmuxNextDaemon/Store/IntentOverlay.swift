import Foundation

/// Applies one intent to the store's records and undoes it exactly
/// (DaemonStore+Intents.swift lifts and restores the overlay around every
/// daemon apply). Kept out of `DaemonStore` so the store type stays within
/// its size ratchet.
@MainActor enum IntentOverlay {
    /// Applies one intent to the records. Idempotent and conservation-safe:
    /// a tab, workspace or group that is not in the mirror, or a value
    /// already in place, changes nothing (returns nil).
    static func apply(_ intent: Intent, to store: DaemonStore) -> IntentUndo? {
        switch intent {
        case .moveTab(let surface, let toPane, let index):
            guard let target = store.panesByHandle[toPane], let source = store.pane(containing: surface),
                  let from = source.tabs.firstIndex(where: { $0.surface == surface }) else { return nil }
            guard let final = OptimisticRules.moveTab(samePane: source === target, from: from, index: index, targetCount: target.tabs.count),
                  let tab = source.removeTab(surface: surface) else { return nil }
            target.insertTab(tab, at: final)
            store.index.insert(tab, in: target)
            store.index.noteTabOrderChanged()
            return .moveTab(surface: surface, fromPane: source.handle, fromIndex: from, toPane: target.handle)
        case .renameTab(let surface, let requested):
            // An empty name clears it, as the daemon stores it.
            let name = requested?.isEmpty == true ? nil : requested
            guard let tab = store.tabsBySurface[surface], tab.name != name else { return nil }
            let previous = tab.name
            tab.setName(name)
            return .tabName(surface: surface, name: previous)
        case .setTabPinned(let surface, let pinned):
            guard let tab = store.tabsBySurface[surface], tab.pinned != pinned else { return nil }
            tab.setPinned(pinned)
            return .tabPinned(surface: surface, pinned: !pinned)
        case .renamePane(let handle, let requested):
            let name = requested?.isEmpty == true ? nil : requested
            guard let pane = store.panesByHandle[handle], pane.name != name else { return nil }
            let previous = pane.name
            pane.name = name
            return .paneName(pane: handle, name: previous)
        case .renameScreen(let handle, let requested):
            let name = requested?.isEmpty == true ? nil : requested
            guard let screen = store.screensByHandle[handle], screen.name != name else { return nil }
            let previous = screen.name
            screen.name = name
            return .screenName(screen: handle, name: previous)
        case .setScreenColor(let handle, let color):
            guard let screen = store.screensByHandle[handle], screen.color != color else { return nil }
            let previous = screen.color
            screen.color = color
            return .screenColor(screen: handle, color: previous)
        case .setScreenIcon(let handle, let icon):
            guard let screen = store.screensByHandle[handle], screen.icon != icon else { return nil }
            let previous = screen.icon
            screen.icon = icon
            return .screenIcon(screen: handle, icon: previous)
        case .setScreenPinned(let handle, let pinned):
            guard let screen = store.screensByHandle[handle], screen.pinned != pinned else { return nil }
            screen.pinned = pinned
            return .screenPinned(screen: handle, pinned: !pinned)
        case .renameWorkspace(let key, let name):
            guard let workspace = store.workspacesByKey[key], workspace.name != name else { return nil }
            let previous = workspace.name
            workspace.setName(name)
            return .workspaceName(key: key, name: previous)
        case .setWorkspaceColor(let key, let color):
            guard let workspace = store.workspacesByKey[key], workspace.color != color else { return nil }
            let previous = workspace.color
            workspace.setColor(color)
            return .workspaceColor(key: key, color: previous)
        case .moveWorkspace(let key, let index):
            guard let from = store.workspaces.firstIndex(where: { $0.key == key }),
                  let current = store.workspaces[checked: from] else { return nil }
            return place(from, .move, group: current.group, index: index, in: store)
        case .setWorkspaceGroup(let key, let group):
            guard let from = store.workspaces.firstIndex(where: { $0.key == key }), group.map({ store.group($0) != nil }) ?? true else { return nil }
            return place(from, .group, group: group, index: from, in: store)
        case .placeWorkspace(let key, let group, let index):
            guard let from = store.workspaces.firstIndex(where: { $0.key == key }), group.map({ store.group($0) != nil }) ?? true else { return nil }
            return place(from, .place, group: group, index: index, in: store)
        case .setWorkspaceGroupCollapsed(let id, let collapsed):
            guard let group = store.group(id), group.collapsed != collapsed else { return nil }
            group.setCollapsed(collapsed)
            return .workspaceGroupCollapsed(id, collapsed: !collapsed)
        case .setTabGroupCollapsed(let id, let collapsed):
            guard let group = store.tabGroupsByID[id], group.collapsed != collapsed else { return nil }
            group.setCollapsed(collapsed)
            return .tabGroupCollapsed(id, collapsed: !collapsed)
        case .setRowHeights(let column, let heights):
            return setRowHeights(heights, of: column, in: store)
        case .createTab(let paneHandle, let provisional):
            // A New Terminal Tab on a pending split's stand-in shows in the daemon's pane once that took it over.
            ProvisionalSplit.rememberStandInTarget(paneHandle, in: store)
            guard let shown = ProvisionalSplit.shownPane(paneHandle, in: store), let pane = store.panesByHandle[shown],
                  store.tabsBySurface[provisional.surface] == nil else { return nil }
            let tab = TabModel(provisional)
            pane.insertTab(tab, at: pane.tabs.count)
            store.index.insert(tab, in: pane)
            return .createdTab(surface: provisional.surface, pane: shown)
        case .createWorkspace(let provisional, let index):
            return ProvisionalWorkspaceOverlay.apply(provisional, index: index, to: store)
        case .closeTabs(let surfaces):
            return TabCloseOverlay(store: store).apply(surfaces)
        case .dockTab(let surface, let pane, let provisional, let dock, let standIn):
            return ProvisionalDock.apply(surface: surface, from: pane, provisional: provisional, dock: dock, standIn: standIn, to: store)
        case .closeStandInPane:
            guard let pane = CancelledCreation.closingPane(intent, in: store), let hidden = CancelledCreation.hidePane(pane, in: store) else { return nil }
            return .hiddenPane(hidden)
        case .splitPane(let target, let direction, let ratio, let provisional):
            return ProvisionalSplit.apply(target: target, direction: direction, ratio: ratio,
                                          provisional: provisional, to: store)
        case .bindAgentSession(let surface, let session, let harness):
            guard let tab = store.tabsBySurface[surface], var record = tab.agentSession,
                  record.session != session || (harness != nil && record.harness != harness) else { return nil }
            let previous = tab.snapshot
            var next = previous
            record.session = session
            record.harness = harness ?? record.harness
            next.conversation = ConversationTabRef(agentSession: record)
            tab.update(next)
            if let pane = store.pane(holding: tab) { store.index.insert(tab, in: pane) }
            return .tabSnapshot(surface: surface, previous: previous)
        }
    }

    /// Writes `heights` onto the column's rows; nil when the column is not
    /// in the mirror, its row set differs (the daemon refuses that,
    /// `row-set-stale`) or nothing changes.
    private static func setRowHeights(_ heights: [RowHeightValue], of column: ColumnID, in store: DaemonStore) -> IntentUndo? {
        for screen in store.screensByHandle.values {
            guard let current = screen.columns.first(where: { $0.id == column }) else { continue }
            guard let next = OptimisticRules.rowHeights(current.rows, heights) else { return nil }
            let previous = current.rows.map { RowHeightValue(row: $0.id, height: $0.height) }
            var entry = current
            entry.rows = zip(entry.rows, next).map { row, height in
                var row = row
                row.height = height.height
                return row
            }
            screen.columns.modifyFirst(where: { $0.id == column }) { $0 = entry }
            return .rowHeights(column: column, heights: previous)
        }
        return nil
    }

    /// Applies a pending intent again after a daemon apply. A created tab the daemon already
    /// reported replaces its provisional one (``ProvisionalTab/created(_:surface:in:)``).
    static func restore(_ pending: PendingIntent, to store: DaemonStore) -> IntentUndo? {
        if pending.closeWhenCreated { return CancelledCreation.hide(pending, in: store) }
        if pending.standInClosed { return CancelledCreation.restoreClosedStandIn(pending, in: store) }
        if let created = pending.createdSurface, store.tabsBySurface[created] != nil {
            guard !pending.createdConfirmed else {
                // A split's tab is confirmed with its pane, before the layout that places the
                // pane: the split still places the daemon's pane until then (cx-ry0y), and only
                // while the records hold that pane (its tab may move out and the pane close first).
                guard case .splitPane(_, _, _, let provisional) = pending.kind,
                      ProvisionalSplit.daemonPane(provisional, in: store) != nil else { return nil }
                return apply(pending.kind, to: store)
            }
            // A guess: the daemon's tab stays out of sight and the stand-in keeps its place, so
            // a wrong guess never shows a tab under another create (tab-spam-race).
            guard let hidden = CancelledCreation.hideTab(created, in: store) else { return nil }
            return .guessedTab(hidden: hidden, provisional: apply(pending.kind, to: store))
        }
        // The daemon's pane under the split's public pane id replaces the provisional one
        // (ProvisionalSplit.apply places it until the daemon's layout does). Once that pane is
        // gone again, a split not yet due shows nothing until it settles (never its stand-in).
        if ProvisionalSplit.paneGone(pending, in: store) { return nil }
        return apply(pending.kind, to: store)
    }

    static func undo(_ undo: IntentUndo, in store: DaemonStore) {
        switch undo {
        case .moveTab(let surface, let fromPane, let fromIndex, let toPane):
            guard let source = store.panesByHandle[fromPane], let target = store.panesByHandle[toPane],
                  let tab = target.removeTab(surface: surface) else {
                return store.reportMirrorViolation("intent overlay undo found surface \(surface) missing from pane \(toPane)")
            }
            source.insertTab(tab, at: fromIndex)
            store.index.insert(tab, in: source)
            store.index.noteTabOrderChanged()
        case .tabName(let surface, let name):
            store.tabsBySurface[surface]?.setName(name)
        case .tabPinned(let surface, let pinned):
            store.tabsBySurface[surface]?.setPinned(pinned)
        case .paneName(let pane, let name):
            store.panesByHandle[pane]?.name = name
        case .screenName(let screen, let name):
            store.screensByHandle[screen]?.name = name
        case .screenColor(let screen, let color):
            store.screensByHandle[screen]?.color = color
        case .screenIcon(let screen, let icon):
            store.screensByHandle[screen]?.icon = icon
        case .screenPinned(let screen, let pinned):
            store.screensByHandle[screen]?.pinned = pinned
        case .workspaceName(let key, let name):
            store.workspacesByKey[key]?.setName(name)
        case .workspaceColor(let key, let color):
            store.workspacesByKey[key]?.setColor(color)
        case .workspacePlace(let key, let index, let group):
            guard let from = store.workspaces.firstIndex(where: { $0.key == key }) else {
                return store.reportMirrorViolation("intent overlay undo found workspace \(key) missing")
            }
            _ = place(at: from, index: index, group: group, in: store)
        case .workspaceGroupCollapsed(let id, let collapsed):
            store.group(id)?.setCollapsed(collapsed)
        case .tabGroupCollapsed(let id, let collapsed):
            store.tabGroupsByID[id]?.setCollapsed(collapsed)
        case .rowHeights(let column, let heights):
            guard setRowHeights(heights, of: column, in: store) != nil else {
                return store.reportMirrorViolation("intent overlay undo found column \(column) without its rows")
            }
        case .tabSnapshot(let surface, let previous):
            guard let tab = store.tabsBySurface[surface] else { return }
            tab.update(previous)
            if let pane = store.pane(holding: tab) { store.index.insert(tab, in: pane) }
        case .hiddenTab, .hiddenPane:
            CancelledCreation.unhide(undo, in: store)
        case .closedTabs(let hidden):
            TabCloseOverlay(store: store).undo(hidden)
        case .guessedTab(let hidden, let provisional):
            if let provisional { self.undo(provisional, in: store) }
            CancelledCreation.unhide(.hiddenTab(hidden), in: store)
        case .splitPane(let screen, let layout, let columns, let pane):
            ProvisionalSplit.undo(screen: screen, layout: layout, columns: columns, pane: pane, in: store)
        case .dockTab(let dock):
            ProvisionalDock.undo(dock, in: store)
        case .closedStandIn(let overlay, let hidden):
            // Applied overlay first, then the hide: undone in reverse.
            if let hidden { CancelledCreation.unhide(.hiddenTab(hidden), in: store) }
            if let overlay { self.undo(overlay, in: store) }
        case .createdWorkspace(let key, let inserted):
            ProvisionalWorkspaceOverlay.undo(key: key, inserted: inserted, in: store)
        case .createdTab(let surface, let pane):
            guard let tab = store.panesByHandle[pane]?.removeTab(surface: surface) else {
                if let stray = store.tabsBySurface[surface] { store.index.remove(stray) }
                return store.reportMirrorViolation("intent overlay undo found provisional surface \(surface) missing from pane \(pane)")
            }
            store.index.remove(tab)
        }
    }

    /// Moves the workspace at `from` to daemon-order `index` in `group`;
    /// returns the inverse, or nil when it was there already.
    private static func place(at from: Int, index: Int, group: WorkspaceGroupID?, in store: DaemonStore) -> IntentUndo? {
        guard let model = store.workspaces[checked: from],
              index != from || model.group != group, let key = model.key else { return nil }
        let undo = IntentUndo.workspacePlace(key: key, index: from, group: model.group)
        model.setGroup(group)
        if index != from {
            store.workspaces.remove(at: from)
            store.workspaces.insert(model, at: index)
            store.index.noteTabOrderChanged()
        }
        store.sidebarNeedsRecompute = true
        return undo
    }

    /// Places the workspace at `from` by `kind` (cmux-layout-reducer `place_workspace`: a move clamps, a regroup
    /// keeps its place, a section index goes before the member now there, after the last one, or stays put in an
    /// empty section); nil when it stays where it is in the group it is in.
    private static func place(_ from: Int, _ kind: OptimisticRules.PlaceKind, group: WorkspaceGroupID?, index: Int,
                              in store: DaemonStore) -> IntentUndo? {
        guard let target = OptimisticRules.placeWorkspace(groups: store.workspaces.map(\.group), from: from, kind: kind,
                                                          group: group, index: index) else { return nil }
        return place(at: from, index: target, group: group, in: store)
    }
}
