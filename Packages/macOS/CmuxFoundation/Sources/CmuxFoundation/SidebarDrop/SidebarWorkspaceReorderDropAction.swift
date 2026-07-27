public import Foundation

/// The commit operation produced by a resolved sidebar workspace drop plan.
public enum SidebarWorkspaceReorderDropAction: Equatable, Sendable {
    /// Reorder a workspace already present in the destination sidebar.
    case reorder(targetIndex: Int, usesTopLevelRows: Bool, explicitGroupId: UUID?)

    /// Insert a workspace dragged from another window at the destination index.
    ///
    /// `insertionIndex` is clamped for the dragged workspace's pin state and
    /// drives the rendered single-workspace plan. `proposedInsertionIndex`
    /// preserves the raw pointer slot so multi-selection commits can clamp each
    /// pin tier independently.
    case crossWindow(insertionIndex: Int, proposedInsertionIndex: Int)
}
