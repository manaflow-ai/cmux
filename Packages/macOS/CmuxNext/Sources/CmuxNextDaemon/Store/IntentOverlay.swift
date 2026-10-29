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
            let final = source === target ? min(max(index, 0), target.tabs.count - 1) : min(max(index, 0), target.tabs.count)
            if source === target, from == final { return nil }
            guard let tab = source.removeTab(surface: surface) else { return nil }
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
            return place(at: from, index: min(max(index, 0), store.workspaces.count - 1), group: current.group, in: store)
        case .setWorkspaceGroup(let key, let group):
            guard let from = store.workspaces.firstIndex(where: { $0.key == key }), group.map({ store.group($0) != nil }) ?? true else { return nil }
            return place(at: from, index: from, group: group, in: store)
        case .placeWorkspace(let key, let group, let index):
            guard let from = store.workspaces.firstIndex(where: { $0.key == key }), group.map({ store.group($0) != nil }) ?? true else { return nil }
            return place(at: from, index: sectionPlacement(from: from, group: group, index: index, in: store), group: group, in: store)
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
            guard let pane = store.panesByHandle[paneHandle], store.tabsBySurface[provisional.surface] == nil else { return nil }
            let tab = TabModel(provisional)
            pane.insertTab(tab, at: pane.tabs.count)
            store.index.insert(tab, in: pane)
            return .createdTab(surface: provisional.surface, pane: paneHandle)
        case .createWorkspace(let provisional, let index):
            return ProvisionalWorkspaceOverlay.apply(provisional, index: index, to: store)
        case .closeTabs(let surfaces):
            return TabCloseOverlay(store: store).apply(surfaces)
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
        let byRow = Dictionary(heights.map { ($0.row, $0.height) }, uniquingKeysWith: { _, new in new })
        for screen in store.screensByHandle.values {
            guard let current = screen.columns.first(where: { $0.id == column }) else { continue }
            var entry = current
            guard Set(entry.rows.map(\.id)) == Set(byRow.keys), entry.rows.count == byRow.count else { return nil }
            let previous = entry.rows.map { RowHeightValue(row: $0.id, height: $0.height) }
            entry.rows = entry.rows.map { row in
                var row = row
                row.height = byRow[row.id] ?? row.height
                return row
            }
            guard entry != current else { return nil }
            screen.columns.modifyFirst(where: { $0.id == column }) { $0 = entry }
            return .rowHeights(column: column, heights: previous)
        }
        return nil
    }

    /// Applies a pending intent again after a daemon apply. A created tab the daemon already
    /// reported replaces its provisional one (``ProvisionalTab/created(_:surface:in:)``).
    static func restore(_ pending: PendingIntent, to store: DaemonStore) -> IntentUndo? {
        if pending.closeWhenCreated { return CancelledCreation.hide(pending, in: store) }
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

    /// cmux-tui's `move-workspace-to-group` placement (presentation.rs
    /// `move_workspace_to_group`) on the records: a section is the daemon
    /// order filtered by group, so the workspace goes before the member now
    /// at `index`, after the last member, or stays put in an empty section.
    /// Kept here because the intent names a section index, which only this
    /// rule turns into a daemon-order index on the current mirror.
    private static func sectionPlacement(from old: Int, group: WorkspaceGroupID?, index: Int, in store: DaemonStore) -> Int {
        let remaining = store.workspaces.indices.filter { $0 != old }
        let members = store.workspaces.enumerated().filter { $0.offset != old && $0.element.group == group }.map(\.offset)
        let position = { (target: Int) in remaining.firstIndex(of: target) ?? old }
        var new = old
        if let last = members.last {
            // A negative section index means the front, as a negative move index does.
            new = members[checked: max(index, 0)].map(position) ?? position(last) + 1
        }
        return min(new, store.workspaces.count - 1)
    }
}
