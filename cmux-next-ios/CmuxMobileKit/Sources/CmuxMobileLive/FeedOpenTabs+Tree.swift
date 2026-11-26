import CmuxMobileFeed
import CmuxMobileModel

extension FeedOpenTabs {
    /// A Mac's open tabs from its own tree: every workspace it lists, its home workspace too
    /// (an agent there reaches the Feed). Complete: a workspace it no longer lists was closed.
    public init(tree: DaemonTree) {
        self.init(workspaces: tree.workspaces + tree.homeWorkspaces, complete: true)
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
