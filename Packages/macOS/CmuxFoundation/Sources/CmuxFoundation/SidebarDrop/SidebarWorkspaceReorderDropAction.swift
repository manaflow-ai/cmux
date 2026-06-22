public import Foundation

/// The commit operation produced by a resolved sidebar workspace drop plan.
public enum SidebarWorkspaceReorderDropAction: Equatable, Sendable {
    /// Reorder a workspace already present in the destination sidebar.
    case reorder(targetIndex: Int, usesTopLevelRows: Bool, explicitGroupId: UUID?)

    /// Insert a workspace dragged from another window at the destination index.
    case crossWindow(insertionIndex: Int)
}
