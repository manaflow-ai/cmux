import Foundation

/// Why a tab dragged in from a pane cannot land on a sidebar row.
public nonisolated enum SidebarTabDropRefusal: Hashable, Sendable {
    /// The row belongs to another machine.
    case otherMachine
    /// The pinned area cannot host a new workspace.
    case pinnedArea
}
