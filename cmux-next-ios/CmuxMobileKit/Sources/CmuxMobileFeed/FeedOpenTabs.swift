import Foundation

/// The tabs one Mac has open, as the phone last heard them: what the Feed checks its rows
/// against, so a row whose tab was closed (on the Mac or on this phone, alone or with its
/// workspace) leaves the Feed. The person closed that tab; its events are no longer news.
///
/// `complete` says whether a workspace missing from `tabsByWorkspace` was closed. The Mac's own
/// tree is complete. The launch snapshot is not (it may hold only the first screen of rows, and
/// never the Mac's home workspace), so before the Mac answers only a tab gone from a workspace
/// the snapshot lists hides its rows.
public struct FeedOpenTabs: Equatable, Sendable {
    public var tabsByWorkspace: [String: Set<String>]
    public var complete: Bool

    public init(tabsByWorkspace: [String: Set<String>], complete: Bool) {
        self.tabsByWorkspace = tabsByWorkspace
        self.complete = complete
    }

    /// Whether `item`'s tab is known to be closed. A row with no tab (an unbound chat, a Mac
    /// request, a Cloud event) is never closed.
    func closes(_ item: FeedItem) -> Bool {
        guard !item.workspaceID.isEmpty, !item.tabID.isEmpty else { return false }
        guard let tabs = tabsByWorkspace[item.workspaceID] else { return complete }
        return !tabs.contains(item.tabID)
    }
}

extension FeedItem {
    /// Whether this row stays in the Feed after its tab closed: a chat's question or approval
    /// still waiting on the person. The acpmux session outlives its tab and stays blocked on the
    /// ask, and the Feed is the one place left to answer it. A terminal's ask goes with its tab:
    /// closing the tab ended the program that asked.
    var outlivesItsTab: Bool { needsYou && !opensTerminal }
}

extension FeedItem {
    /// A re-read of this row that no longer finds its tab (a chat whose tab closed: its session
    /// is placed nowhere) keeps the tab it had, so the Feed still knows which tab closed.
    mutating func keepPlace(of known: FeedItem) {
        guard workspaceID.isEmpty, !known.workspaceID.isEmpty else { return }
        workspaceID = known.workspaceID
        tabID = known.tabID
        workspaceTitle = known.workspaceTitle
        tabTitle = known.tabTitle
    }
}
