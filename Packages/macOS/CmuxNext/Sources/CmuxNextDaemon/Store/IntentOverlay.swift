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
        case .renameWorkspace(let key, let name):
            guard let workspace = store.workspacesByKey[key], workspace.name != name else { return nil }
            let previous = workspace.name
            workspace.setName(name)
            return .workspaceName(key: key, name: previous)
        case .moveWorkspace(let key, let index):
            guard let from = store.workspaces.firstIndex(where: { $0.key == key }) else { return nil }
            return place(at: from, index: min(max(index, 0), store.workspaces.count - 1), group: store.workspaces[from].group, in: store)
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
        }
    }

    static func undo(_ undo: IntentUndo, in store: DaemonStore) {
        switch undo {
        case .moveTab(let surface, let fromPane, let fromIndex, let toPane):
            guard let source = store.panesByHandle[fromPane], let target = store.panesByHandle[toPane],
                  let tab = target.removeTab(surface: surface) else {
                return store.reportMirrorViolation("intent overlay undo found surface \(surface) missing from pane \(toPane)")
            }
            source.insertTab(tab, at: fromIndex)
        case .tabName(let surface, let name):
            store.tabsBySurface[surface]?.setName(name)
        case .tabPinned(let surface, let pinned):
            store.tabsBySurface[surface]?.setPinned(pinned)
        case .workspaceName(let key, let name):
            store.workspacesByKey[key]?.setName(name)
        case .workspacePlace(let key, let index, let group):
            guard let from = store.workspaces.firstIndex(where: { $0.key == key }) else {
                return store.reportMirrorViolation("intent overlay undo found workspace \(key) missing")
            }
            _ = place(at: from, index: index, group: group, in: store)
        case .workspaceGroupCollapsed(let id, let collapsed):
            store.group(id)?.setCollapsed(collapsed)
        case .tabGroupCollapsed(let id, let collapsed):
            store.tabGroupsByID[id]?.setCollapsed(collapsed)
        }
    }

    /// Moves the workspace at `from` to daemon-order `index` in `group`;
    /// returns the inverse, or nil when it was there already.
    private static func place(at from: Int, index: Int, group: WorkspaceGroupID?, in store: DaemonStore) -> IntentUndo? {
        let model = store.workspaces[from]
        guard index != from || model.group != group, let key = model.key else { return nil }
        let undo = IntentUndo.workspacePlace(key: key, index: from, group: model.group)
        model.setGroup(group)
        if index != from {
            store.workspaces.remove(at: from)
            store.workspaces.insert(model, at: index)
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
        let members = remaining.filter { store.workspaces[$0].group == group }
        let position = { (target: Int) in remaining.firstIndex(of: target) ?? old }
        var new = old
        if let last = members.last {
            new = index < members.count ? position(members[index]) : position(last) + 1
        }
        return min(new, store.workspaces.count - 1)
    }
}
