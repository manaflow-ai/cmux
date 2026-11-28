import CmuxMobileFeed
import CmuxMobileModel

extension FeedOpenTabs {
    /// A Mac's open tabs from its own tree: every workspace it lists, its home workspace too
    /// (an agent there reaches the Feed). Complete: a workspace it no longer lists was closed.
    public init(tree: DaemonTree) {
        self.init(workspaces: tree.workspaces + tree.homeWorkspaces, complete: true)
    }

    /// The open tabs of `workspaceIDs`' workspaces in `tree`, nil for one it no longer lists:
    /// what ``FeedStore/updateOpenTabs(_:macID:whole:)`` takes for a row delta. Each entry equals
    /// the one `init(tree:)` builds (a workspace listed twice, as a row and as home, unions both).
    /// It reads only the changed workspaces' tabs: an ID check per row, no set per tab.
    public static func changedTabs(in tree: DaemonTree, workspaceIDs: Set<String>) -> [String: Set<String>?] {
        var changed: [String: Set<String>?] = [:]
        guard !workspaceIDs.isEmpty else { return changed }
        changed.reserveCapacity(workspaceIDs.count)
        for id in workspaceIDs { changed[id] = .some(nil) }
        for list in [tree.workspaces, tree.homeWorkspaces] {
            for workspace in list where workspaceIDs.contains(workspace.id) {
                var tabs = changed[workspace.id].flatMap { $0 } ?? []
                tabs.formUnion(workspace.tabs.lazy.map(\.id))
                changed[workspace.id] = .some(tabs)
            }
        }
        return changed
    }

    /// Open tabs from `workspaces`. `complete` only when no workspace of the Mac is missing
    /// from them (the Mac's tree); a launch snapshot's rows are not (``FeedOpenTabs``).
    public init(workspaces: [Workspace], complete: Bool) {
        var tabs: [String: Set<String>] = [:]
        tabs.reserveCapacity(workspaces.count)
        for workspace in workspaces {
            tabs[workspace.id, default: []].formUnion(workspace.tabs.lazy.map(\.id))
        }
        self.init(tabsByWorkspace: tabs, complete: complete)
    }
}
