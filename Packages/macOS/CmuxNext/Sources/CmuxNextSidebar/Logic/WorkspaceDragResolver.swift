public import CmuxNextDesign
public import CoreGraphics

/// Where a sidebar workspace drag lands inside a window.
public enum WorkspaceDropTarget: Hashable {
    /// A slot in the window's sidebar (a gap opened there).
    case position(DropPosition)
    /// A group header in the window's sidebar.
    case intoGroup(GroupID)
    /// Anywhere else in the window: appended to its sidebar.
    case window
    /// A pane of the window's shown workspace: the dragged workspace's tabs
    /// join that pane (`.strip`) or a new split, column or dock there, and
    /// the emptied workspace closes (`TabDragSession+WorkspaceMerge`).
    case merge(TabDropKind)
    /// A pane edge of the window's shown workspace with Debug Settings `sidebar.multiView` on: the dragged
    /// workspace shows on that side of the shown one, whole (`WindowController.placeBeside`).
    case beside(TabDropEdge)
}

/// How a sidebar workspace drag ends. Window membership is frontend-local
/// (`WindowRegistry`); a sidebar slot adds one daemon order command per
/// workspace, a group header one move-to-group each.
public enum WorkspaceDragOutcome: Hashable {
    case window(id: String, target: WorkspaceDropTarget)
    /// Released outside every window: a new window under the pointer.
    case newWindow(screenPoint: CGPoint)
    /// Released outside every window with every workspace of the source
    /// window: that window moves under the pointer instead.
    case moveWindow(screenPoint: CGPoint)
    case cancel
}

/// Outcome resolution for workspace drags, asked of Rust (cmux-layout-reducer
/// `drop_rules`, op `drop_workspace_outcome`, with its table tests). The app
/// hits the sidebar and the panes; Rust says what the hit means.
public enum WorkspaceDragResolver {
    /// - Parameters:
    ///   - windowID: the frontmost window under the pointer, nil outside all.
    ///   - sidebarHit: that window's sidebar target, if the pointer is on it.
    ///   - layoutHit: the pane target under the pointer, when the drag can
    ///     merge into the window's shown workspace.
    ///   - placesBeside: a pane edge places the workspace beside the shown
    ///     one instead of merging it (`sidebar.multiView`).
    ///   - isGroup: the drag carries a whole workspace group (never placed
    ///     at a slot or into another group).
    ///   - besideEdge: the shown workspace's edge near the pointer (`WindowController.besideEdge`). With
    ///     `placesBeside` it places the workspace beside where the layout has no pane target: a pane that takes no
    ///     drop (Home's pinned dock) or a screen edge dock band (`WorkspaceMerge.hit`).
    public static func outcome(windowID: String?, sidebarHit: WorkspaceDropTarget?, layoutHit: TabDropKind? = nil, placesBeside: Bool = false,
                        sourceWindowID: String?, draggingAllOfSource: Bool, isGroup: Bool, screenPoint: CGPoint,
                        besideEdge: TabDropEdge? = nil) -> WorkspaceDragOutcome {
        let request = WorkspaceDragWire.Drag(windowID: windowID, sidebarHit: sidebarHit, layoutHit: layoutHit, placesBeside: placesBeside,
                                             sourceWindowID: sourceWindowID, draggingAllOfSource: draggingAllOfSource, isGroup: isGroup,
                                             besideEdge: besideEdge)
        let reply = DropRules.call("drop_workspace_outcome", request, as: WorkspaceDragWire.Outcome.self)
        return reply?.resolved(sidebarHit: sidebarHit, layoutHit: layoutHit, screenPoint: screenPoint) ?? .cancel
    }

    public static func target(for drop: SidebarTabDrop) -> WorkspaceDropTarget {
        switch drop {
        case let .newWorkspace(section, group, index): .position(DropPosition(section: section, group: group, index: index))
        case let .intoGroup(group): .intoGroup(group)
        case .intoWorkspace: .window
        }
    }
}
