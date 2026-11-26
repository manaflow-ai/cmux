public import CmuxNextDesign
public import CoreGraphics
public import Foundation

/// How a tab drag ends. The App maps each case to exactly one daemon
/// command (plans/cmux-next/REWRITE.md "Tab drag").
public nonisolated enum TabDragOutcome: Hashable, Sendable {
    /// Into a tab strip at `index` (final display index), joining `groupID`.
    case strip(stripID: UUID, index: Int, groupID: String?)
    /// New pane on `edge` of the layout pane `paneID`.
    case newSplit(paneID: String, edge: TabDropEdge)
    /// New strip column on `screenID` after `afterColumnID`.
    case newColumn(screenID: String, afterColumnID: String)
    /// New top or bottom dock on `screenID` holding the tab
    /// (move-tab-to-column with `dock`, edge-docks-v1).
    case newDock(screenID: String, edge: String)
    /// New workspace at root `index`, inside `groupID` when non-nil.
    case newWorkspace(groupID: String?, index: Int?)
    /// Into an existing workspace.
    case workspace(id: String)
    /// Released outside every window: new workspace in a new window whose
    /// tab strip sits under `screenPoint`.
    case tearOff(screenPoint: CGPoint)
    /// Released outside every window while dragging everything the source
    /// workspace holds, the only workspace of its window: the source window
    /// moves under the pointer instead, as when dragging a window's only tab.
    /// No daemon command.
    case moveWindow(screenPoint: CGPoint)
    /// Released outside every window while dragging everything the source
    /// workspace holds, whose window lists other workspaces too: the
    /// workspace itself moves to a new window under the pointer. No daemon
    /// command (window membership is frontend-local).
    case moveWorkspaceToNewWindow(screenPoint: CGPoint)
    /// Dropped on a sidebar gap while dragging everything the source
    /// workspace holds: the workspace itself moves to that slot (root
    /// `index`, inside `groupID` when non-nil) in the drop window, instead
    /// of a new workspace next to an emptied one.
    case moveWorkspace(groupID: String?, index: Int?)
    /// No valid target: spring back to the origin.
    case cancel
}

/// What the resolver needs to know about the drag's source.
public nonisolated struct TabDragContext: Hashable, Sendable {
    /// Layout pane id (`PaneModel.id`) of the source pane.
    public var sourcePaneID: String
    /// Tabs in the source pane, including the dragged ones.
    public var sourcePaneTabCount: Int
    public var sourceWorkspaceID: String
    /// Tabs in the whole source workspace, including the dragged ones.
    public var sourceWorkspaceTabCount: Int
    /// Tabs being dragged (1, or a group's member count).
    public var draggedTabCount: Int
    /// Workspaces the source window lists (1 when it shows only this one).
    public var sourceWindowWorkspaceCount: Int
    /// The source strip (`TabStripModel.stripID`) and the dragged tab's (or
    /// group's first tab's) index in its display order; nil for workspace drags.
    public var sourceStripID: UUID?
    public var sourceIndex: Int?
    /// The tab group the dragged tab is in (nil: none, or a group drag).
    public var sourceGroupID: String?
    /// The drag carries a whole tab group (not a single tab).
    public var isGroupDrag = false
    /// The dragged tabs stay in their workspace (Home's own tab, Leo
    /// 2026-10-09): they never become a new workspace or a new window. The
    /// other tabs of Home drag out like any (`TabPromotion`).
    public var sourceStaysPut = false

    public init(sourcePaneID: String, sourcePaneTabCount: Int, sourceWorkspaceID: String,
                sourceWorkspaceTabCount: Int, draggedTabCount: Int, sourceWindowWorkspaceCount: Int = 1,
                sourceStripID: UUID? = nil, sourceIndex: Int? = nil, sourceGroupID: String? = nil) {
        self.sourcePaneID = sourcePaneID
        self.sourcePaneTabCount = sourcePaneTabCount
        self.sourceWorkspaceID = sourceWorkspaceID
        self.sourceWorkspaceTabCount = sourceWorkspaceTabCount
        self.draggedTabCount = draggedTabCount
        self.sourceWindowWorkspaceCount = sourceWindowWorkspaceCount
        self.sourceStripID = sourceStripID
        self.sourceIndex = sourceIndex
        self.sourceGroupID = sourceGroupID
    }

    /// A split onto `pane` with every tab it holds: the tabs stay and the
    /// New Tab page opens on the far side (`TabMoves.splitBehind`), where
    /// classic cmux fills bonsplit's placeholder (#22287). Never refused.
    /// The rule is Rust's (`tab_drag_rule_context`); false when it does not answer.
    public func splitsBehind(pane: String) -> Bool {
        TabDragResolver.Wire.context(self, pane: pane)?.splitsBehind ?? false
    }

    /// The drag carries every tab of its pane: the pane closes when they leave.
    public var emptiesSourcePane: Bool { TabDragResolver.Wire.context(self)?.emptiesSourcePane ?? false }
    /// The drag carries every tab of its workspace (the last tab of the last
    /// pane): the workspace moves with it, or closes once they land in
    /// another workspace (coordinator decision 2026-09-30).
    public var emptiesSourceWorkspace: Bool { TabDragResolver.Wire.context(self)?.emptiesSourceWorkspace ?? false }
}

/// Outcome resolution from drop-target proposals. The session asks
/// surfaces in priority order (sidebar, strips, layout) and resolves the
/// first that answers (`resolve`); the rules are Rust's
/// (cmux-layout-reducer `tab_drag_rules`, `tab_drag_rule_*`).
public nonisolated enum TabDragResolver {}
