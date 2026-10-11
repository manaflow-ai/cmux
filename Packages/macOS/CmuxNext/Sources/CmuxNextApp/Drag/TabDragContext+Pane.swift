import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextTabs

extension TabDragContext {
    /// The resolver's facts about a drag of `item` out of `pane`.
    init(pane: PaneController, item: TabDragSession.Item, draggedCount: Int) {
        let workspaceTabs = pane.workspace?.workspace.screens.flatMap(\.panes).reduce(0) { $0 + $1.tabs.count } ?? pane.pane.tabs.count
        let ordered = pane.stripModel.orderedTabs
        let first: String? = switch item {
        case .tab(let id): id
        case .group(_, let members): members.first
        case .workspaces: nil
        }
        let index = first.flatMap { id in ordered.firstIndex { $0.id.rawValue == id } }
        let group: String? = if case .tab = item, let index { ordered[index].groupID?.rawValue } else { nil }
        self.init(sourcePaneID: pane.layoutPaneID.rawValue, sourcePaneTabCount: pane.pane.tabs.count,
                  sourceWorkspaceID: pane.workspace?.workspace.id ?? "", sourceWorkspaceTabCount: workspaceTabs,
                  draggedTabCount: draggedCount, sourceStripID: pane.stripModel.stripID, sourceIndex: index,
                  sourceGroupID: group)
        if case .group = item { isGroupDrag = true }
        sourceStaysPut = TabPromotion.staysPut(kind: pane.workspace?.workspace.kind)
        // A single daemon tab of a kind that can respawn, on a daemon that
        // splits a pane with its only tab by spawning a fresh one there.
        if case .tab(let id) = item, let tab = pane.pane.tabs.first(where: { $0.id == id }),
           TabMoves.respawn(for: tab, in: pane.pane, services: pane.services) != nil {
            respawnsOnSplit = pane.services.machines.daemon(forPane: pane.pane).supports(DaemonCapabilities.shared.tabSplitRespawn)
        }
    }
}
