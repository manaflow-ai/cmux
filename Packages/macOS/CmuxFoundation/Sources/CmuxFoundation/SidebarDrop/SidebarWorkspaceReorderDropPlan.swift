public import Foundation

/// A resolved sidebar workspace drop, including both visual and commit intent.
public struct SidebarWorkspaceReorderDropPlan: Equatable, Sendable {
    /// The workspace being dragged.
    public let draggedWorkspaceId: UUID

    /// The indicator the UI should render for this exact drop intent.
    public let indicator: SidebarDropIndicator?

    /// The visible row scope where ``indicator`` should be rendered.
    public let indicatorScope: SidebarWorkspaceReorderDropIndicatorScope

    /// The commit operation to perform if the drag is dropped at this point.
    public let action: SidebarWorkspaceReorderDropAction

    /// Pin state the dragged top-level row must adopt to honor the pointer slot.
    /// `nil` keeps the current effective pin state.
    public let targetPinnedState: Bool?

    /// Creates a resolved workspace drop plan.
    ///
    /// - Parameters:
    ///   - draggedWorkspaceId: The workspace being dragged.
    ///   - indicator: The indicator the UI should render for this exact drop intent.
    ///   - indicatorScope: The visible row scope where `indicator` should be rendered.
    ///   - action: The commit operation to perform if the drag is dropped at this point.
    ///   - targetPinnedState: Pin state transition needed to honor the pointer slot.
    public init(
        draggedWorkspaceId: UUID,
        indicator: SidebarDropIndicator?,
        indicatorScope: SidebarWorkspaceReorderDropIndicatorScope = .raw,
        action: SidebarWorkspaceReorderDropAction,
        targetPinnedState: Bool? = nil
    ) {
        self.draggedWorkspaceId = draggedWorkspaceId
        self.indicator = indicator
        self.indicatorScope = indicatorScope
        self.action = action
        self.targetPinnedState = targetPinnedState
    }
}
