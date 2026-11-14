import Foundation

/// Which tab a workspace opens on. Pure: what the open knows in, a tab out.
///
/// In order, skipping a tab the workspace no longer lists:
/// 1. `requested`: a tab the open names (a notification or link with a tab, a Feed card, a
///    needs-you row, a row menu's tab, a search result, a new workspace's first tab, the
///    relaunch restore).
/// 2. `lastActive`: the tab on screen when the person last left this workspace in this
///    launch, so going back to the list and in again lands where they were (Leo 2026-11-14:
///    "when I go back to the workspace, it opens it up at the first one instead of my recently
///    opened one, which seems kind of weird if it's still loaded on my phone").
/// 3. The active tab of the layout's leftmost, topmost pane (`WorkspaceLayout.topLeftTabID`):
///    a workspace's first open in a launch (user 2026-11-11, #41718).
/// 4. The tab on screen on the Mac, then the first tab.
public struct WorkspaceOpeningTab: Equatable, Sendable {
    public var requested: String?
    public var lastActive: String?

    public init(requested: String? = nil, lastActive: String? = nil) {
        self.requested = requested
        self.lastActive = lastActive
    }

    public func tab(in workspace: Workspace) -> WorkspaceTab? {
        let candidates = [requested, lastActive, workspace.layout?.topLeftTabID, workspace.activeTabID]
        for case let id? in candidates {
            if let tab = workspace.tabs.first(where: { $0.id == id }) { return tab }
        }
        return workspace.tabs.first
    }
}
