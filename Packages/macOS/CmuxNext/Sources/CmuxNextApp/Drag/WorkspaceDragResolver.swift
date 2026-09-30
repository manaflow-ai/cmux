import CmuxNextBridge
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
    ///   - isGroup: the drag carries a whole workspace group (never placed
    ///     at a slot or into another group).
    static func outcome(windowID: String?, sidebarHit: WorkspaceDropTarget?, sourceWindowID: String?,
                        draggingAllOfSource: Bool, isGroup: Bool, screenPoint: CGPoint) -> WorkspaceDragOutcome {
        guard let windowID else {
            return draggingAllOfSource ? .moveWindow(screenPoint: screenPoint) : .newWindow(screenPoint: screenPoint)
        }
        // A group keeps its members together: it joins the window as a
        // whole, where its own position in the daemon order puts it.
        let target = isGroup ? .window : sidebarHit ?? .window
        if windowID == sourceWindowID {
            // Back home: only a sidebar slot means something (a reorder).
            guard case .position = target else { return .cancel }
        }
        return .window(id: windowID, target: target)
    }

    static func target(for drop: SidebarTabDrop) -> WorkspaceDropTarget {
        switch drop {
        case let .newWorkspace(section, group, index): .position(DropPosition(section: section, group: group, index: index))
        case let .intoGroup(group): .intoGroup(group)
        case .intoWorkspace: .window
        }
    }
}
