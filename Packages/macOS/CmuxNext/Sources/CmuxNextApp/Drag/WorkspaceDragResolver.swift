import CmuxNextBridge
import CmuxNextDesign
import CmuxNextSidebar
import CoreGraphics

/// Where a sidebar workspace drag lands inside a window.
enum WorkspaceDropTarget: Hashable {
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
enum WorkspaceDragOutcome: Hashable {
    case window(id: String, target: WorkspaceDropTarget)
    /// Released outside every window: a new window under the pointer.
    case newWindow(screenPoint: CGPoint)
    /// Released outside every window with every workspace of the source
    /// window: that window moves under the pointer instead.
    case moveWindow(screenPoint: CGPoint)
    case cancel
}

/// Pure outcome resolution for workspace drags (tested without windows).
enum WorkspaceDragResolver {
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
    static func outcome(windowID: String?, sidebarHit: WorkspaceDropTarget?, layoutHit: TabDropKind? = nil, placesBeside: Bool = false,
                        sourceWindowID: String?, draggingAllOfSource: Bool, isGroup: Bool, screenPoint: CGPoint,
                        besideEdge: TabDropEdge? = nil) -> WorkspaceDragOutcome {
        guard let windowID else {
            return draggingAllOfSource ? .moveWindow(screenPoint: screenPoint) : .newWindow(screenPoint: screenPoint)
        }
        // A group keeps its members together: it joins the window as a
        // whole, where its own position in the daemon order puts it.
        let beside = placesBeside ? besideEdge.map(WorkspaceDropTarget.beside) : nil
        let target: WorkspaceDropTarget = isGroup ? .window : sidebarHit ?? layoutHit.map { pane(target: $0, placesBeside: placesBeside) } ?? beside ?? .window
        if windowID == sourceWindowID {
            // Back home: only a sidebar slot (a reorder) or a pane (a
            // merge) means something.
            switch target {
            case .position, .merge, .beside: break
            case .intoGroup, .window: return .cancel
            }
        }
        return .window(id: windowID, target: target)
    }

    /// A pane target: a split edge places the workspace beside the shown one when `placesBeside`; the rest merge.
    static func pane(target kind: TabDropKind, placesBeside: Bool) -> WorkspaceDropTarget {
        guard placesBeside, case let .newSplit(_, edge) = kind else { return .merge(kind) }
        return .beside(edge)
    }

    static func target(for drop: SidebarTabDrop) -> WorkspaceDropTarget {
        switch drop {
        case let .newWorkspace(section, group, index): .position(DropPosition(section: section, group: group, index: index))
        case let .intoGroup(group): .intoGroup(group)
        case .intoWorkspace: .window
        }
    }
}
