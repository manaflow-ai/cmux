public import Foundation

/// The tab layout as data (workspaces, panes, tabs) and what each drag
/// outcome does to it: the executable reference of the daemon's tab-drag-v1
/// semantics (plans/cmux-next/layout-invariants.md). Tests drive the drop
/// resolver against it and check `LayoutInvariants` after every outcome.
public nonisolated struct LayoutModel: Hashable, Sendable {
    public struct Pane: Hashable, Sendable {
        public var id: String
        public var stripID: UUID
        public var tabs: [String]
        public init(id: String, stripID: UUID = UUID(), tabs: [String]) {
            self.id = id
            self.stripID = stripID
            self.tabs = tabs
        }
    }

    public struct Workspace: Hashable, Sendable {
        public var id: String
        public var panes: [Pane]
        public init(id: String, panes: [Pane]) {
            self.id = id
            self.panes = panes
        }
    }

    public var workspaces: [Workspace]
    /// Ids for panes and workspaces an outcome creates.
    public var nextID = 0

    public init(workspaces: [Workspace]) {
        self.workspaces = workspaces
    }

    public var allTabs: [String] { workspaces.flatMap(\.panes).flatMap(\.tabs) }

    /// (workspace index, pane index) of the pane holding `tab`.
    public func location(of tab: String) -> (workspace: Int, pane: Int)? {
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
    public func context(dragging tab: String, windowWorkspaceCount: Int = 1) -> TabDragContext? {
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
    public func applying(_ outcome: TabDragOutcome, dragging tab: String) -> LayoutModel? {
        var model = self
        guard model.location(of: tab) != nil else { return nil }
        switch outcome {
        case .cancel, .moveWindow, .moveWorkspaceToNewWindow, .moveWorkspace:
            return model
        case .strip(let stripID, let index, _):
            guard model.location(strip: stripID) != nil else { return nil }
            model.remove(tab)
            // The target strip may be the source: look it up after removal.
            guard let (w, p) = model.location(strip: stripID) else { return nil }
            let count = model.workspaces[w].panes[p].tabs.count
            model.workspaces[w].panes[p].tabs.insert(tab, at: min(max(index, 0), count))
        case .newSplit(let paneID, _):
            guard model.location(pane: paneID) != nil else { return nil }
            model.remove(tab)
            // Splitting a pane that just closed (its only tab left) is a loss.
            guard let (w, p) = model.location(pane: paneID) else { return nil }
            model.workspaces[w].panes.insert(model.makePane([tab]), at: p + 1)
        case .newColumn:
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
public nonisolated enum LayoutInvariants {
    /// Violations of: I1 tab conservation (the set of tabs is unchanged; only
    /// a close removes one), I2 every tab in exactly one pane, I3 no empty
    /// pane or workspace. Empty when all hold.
    public static func violations(before: LayoutModel, after: LayoutModel) -> [String] {
        var found: [String] = []
        let old = before.allTabs, new = after.allTabs
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
