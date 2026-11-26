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

    /// Creates a resolved workspace drop plan.
    ///
    /// - Parameters:
    ///   - draggedWorkspaceId: The workspace being dragged.
    ///   - indicator: The indicator the UI should render for this exact drop intent.
    ///   - indicatorScope: The visible row scope where `indicator` should be rendered.
    ///   - action: The commit operation to perform if the drag is dropped at this point.
    public init(
        draggedWorkspaceId: UUID,
        indicator: SidebarDropIndicator?,
        indicatorScope: SidebarWorkspaceReorderDropIndicatorScope = .raw,
        action: SidebarWorkspaceReorderDropAction
    ) {
        self.draggedWorkspaceId = draggedWorkspaceId
        self.indicator = indicator
        self.indicatorScope = indicatorScope
        self.action = action
    }
}
