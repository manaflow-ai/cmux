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
        // Only Home's own tab stays in Home; the tabs right of its dock drag out like any (TabPromotion).
        let dragged: [String] = switch item {
        case .tab(let id): [id]
        case .group(_, let members): members
        case .workspaces: []
        }
        let workspace = pane.workspace?.workspace
        sourceStaysPut = dragged.isEmpty ? TabPromotion.staysPut(kind: workspace?.kind)
            : dragged.contains { TabPromotion.staysPut(tab: $0, in: workspace) }
    }
}
