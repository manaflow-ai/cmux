import Foundation
@testable import CmuxNextBridge

/// The tab layout as data (workspaces, panes, tabs) and what each drag
/// outcome does to it: the executable reference of the daemon's tab-drag-v1
/// semantics (plans/cmux-next/layout-invariants.md). Tests drive the drop
/// resolver against it and check `LayoutInvariants` after every outcome.
nonisolated struct LayoutModel: Hashable, Sendable {
    struct Pane: Hashable, Sendable {
        var id: String
        var stripID: UUID
        var tabs: [String]
        init(id: String, stripID: UUID = UUID(), tabs: [String]) {
            self.id = id
            self.stripID = stripID
            self.tabs = tabs
        }
    }

    struct Workspace: Hashable, Sendable {
        var id: String
        var panes: [Pane]
        init(id: String, panes: [Pane]) {
            self.id = id
            self.panes = panes
        }
    }

    var workspaces: [Workspace]
    /// Ids for panes and workspaces an outcome creates.
    var nextID = 0
    /// Tabs an outcome created explicitly (a respawn).
    var created: Set<String> = []

    init(workspaces: [Workspace]) {
        self.workspaces = workspaces
    }

    var allTabs: [String] { workspaces.flatMap(\.panes).flatMap(\.tabs) }

    /// (workspace index, pane index) of the pane holding `tab`.
    func location(of tab: String) -> (workspace: Int, pane: Int)? {
        for (w, workspace) in workspaces.enumerated() {
            if let p = workspace.panes.firstIndex(where: { $0.tabs.contains(tab) }) { return (w, p) }
        }
        return nil
    }

    func location(pane id: String) -> (workspace: Int, pane: Int)? {
        for (w, workspace) in workspaces.enumerated() {
            if let p = workspace.panes.firstIndex(where: { $0.id == id }) { return (w, p) }
        }
        return nil
    }

    func location(strip id: UUID) -> (workspace: Int, pane: Int)? {
        for (w, workspace) in workspaces.enumerated() {
            if let p = workspace.panes.firstIndex(where: { $0.stripID == id }) { return (w, p) }
        }
        return nil
    }

    /// The resolver's view of a drag of `tab`.
    func context(dragging tab: String, windowWorkspaceCount: Int = 1) -> TabDragContext? {
        guard let (w, p) = location(of: tab) else { return nil }
        let pane = workspaces[w].panes[p]
        return TabDragContext(sourcePaneID: pane.id, sourcePaneTabCount: pane.tabs.count, sourceWorkspaceID: workspaces[w].id,
                              sourceWorkspaceTabCount: workspaces[w].panes.reduce(0) { $0 + $1.tabs.count }, draggedTabCount: 1,
                              sourceWindowWorkspaceCount: windowWorkspaceCount, sourceStripID: pane.stripID,
                              sourceIndex: pane.tabs.firstIndex(of: tab))
    }

    /// Applies `outcome` for a drag of `tab`. Returns nil when the outcome
    /// names a target that does not exist (the daemon rejects it; the
    /// layout is unchanged). Panes and workspaces left empty close.
    func applying(_ outcome: TabDragOutcome, dragging tab: String, respawns: Bool = false) -> LayoutModel? {
        var model = self
        guard model.location(of: tab) != nil else { return nil }
        switch outcome {
        case .cancel, .moveWindow, .moveWorkspaceToNewWindow, .moveWorkspace:
            return model
        case .strip(let stripID, let index, _):
            guard let target = model.location(strip: stripID) else { return nil }
            if let source = model.location(of: tab), source == target {
                // A reorder inside its own pane never closes the pane.
                var tabs = model.workspaces[source.workspace].panes[source.pane].tabs
                tabs.removeAll { $0 == tab }
                tabs.insert(tab, at: min(max(index, 0), tabs.count))
                model.workspaces[source.workspace].panes[source.pane].tabs = tabs
                return model
            }
            model.remove(tab)
            // The target strip may be the source: look it up after removal.
            guard let (w, p) = model.location(strip: stripID) else { return nil }
            let count = model.workspaces[w].panes[p].tabs.count
            model.workspaces[w].panes[p].tabs.insert(tab, at: min(max(index, 0), count))
        case .newSplit(let paneID, _):
            guard let target = model.location(pane: paneID) else { return nil }
            // Splitting the tab's own pane with its only tab: the owner
            // spawns a new tab of the same kind there (an explicit creation).
            if respawns, let source = model.location(of: tab), source == target,
               model.workspaces[source.workspace].panes[source.pane].tabs == [tab] {
                let fresh = model.makeID("t")
                model.workspaces[source.workspace].panes[source.pane].tabs = [fresh]
                model.created.insert(fresh)
                model.workspaces[source.workspace].panes.insert(model.makePane([tab]), at: source.pane + 1)
                return model
            }
            model.remove(tab)
            // Splitting a pane that just closed (its only tab left) is a loss.
            guard let (w, p) = model.location(pane: paneID) else { return nil }
            model.workspaces[w].panes.insert(model.makePane([tab]), at: p + 1)
        case .newColumn, .newDock:
            guard let (w, _) = model.location(of: tab) else { return nil }
            model.remove(tab)
            let target = min(w, model.workspaces.count - 1)
            if target >= 0, model.workspaces.indices.contains(target) {
                model.workspaces[target].panes.append(model.makePane([tab]))
            } else {
                model.workspaces.append(Workspace(id: model.makeID("w"), panes: [model.makePane([tab])]))
            }
        case .newWorkspace, .tearOff:
            model.remove(tab)
            model.workspaces.append(Workspace(id: model.makeID("w"), panes: [model.makePane([tab])]))
        case .workspace(let id):
            guard model.workspaces.contains(where: { $0.id == id }) else { return nil }
            model.remove(tab)
            guard let w = model.workspaces.firstIndex(where: { $0.id == id }), !model.workspaces[w].panes.isEmpty else { return nil }
            model.workspaces[w].panes[0].tabs.append(tab)
        }
        return model
    }

    private mutating func remove(_ tab: String) {
        guard let (w, p) = location(of: tab) else { return }
        workspaces[w].panes[p].tabs.removeAll { $0 == tab }
        if workspaces[w].panes[p].tabs.isEmpty { workspaces[w].panes.remove(at: p) }
        if workspaces[w].panes.isEmpty { workspaces.remove(at: w) }
    }

    private mutating func makeID(_ prefix: String) -> String {
        nextID += 1
        return "\(prefix)-new-\(nextID)"
    }

    private mutating func makePane(_ tabs: [String]) -> Pane {
        Pane(id: makeID("p"), tabs: tabs)
    }
}

/// The layout invariants every drag outcome keeps (plans/cmux-next/layout-invariants.md).
nonisolated enum LayoutInvariants {
    /// Violations of: I1 tab conservation (the set of tabs is unchanged; only
    /// a close removes one), I2 every tab in exactly one pane, I3 no empty
    /// pane or workspace. Empty when all hold.
    static func violations(before: LayoutModel, after: LayoutModel) -> [String] {
        var found: [String] = []
        let old = before.allTabs, new = after.allTabs.filter { !after.created.contains($0) || before.created.contains($0) }
        if Set(old) != Set(new) {
            found.append("I1 tabs lost \(Set(old).subtracting(new).sorted()) added \(Set(new).subtracting(old).sorted())")
        }
        if new.count != Set(new).count { found.append("I2 a tab is in more than one pane") }
        for workspace in after.workspaces {
            if workspace.panes.isEmpty { found.append("I3 workspace \(workspace.id) has no pane") }
            for pane in workspace.panes where pane.tabs.isEmpty { found.append("I3 pane \(pane.id) has no tab") }
        }
        return found
    }
}
