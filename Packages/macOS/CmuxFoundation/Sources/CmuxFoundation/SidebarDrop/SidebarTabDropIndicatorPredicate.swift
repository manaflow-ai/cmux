public import Foundation

/// Pure predicates deciding when a sidebar row (or the empty area below all
/// rows) should render its drop indicator for a given drag state.
public struct SidebarTabDropIndicatorPredicate {
    /// Creates a sidebar drop-indicator predicate evaluator.
    public init() {}

    /// Returns whether the top-edge indicator should render above a row.
    ///
    /// - Parameters:
    ///   - tabId: The row currently being rendered.
    ///   - draggedTabId: The workspace currently being dragged, if any.
    ///   - dropIndicator: The resolved sidebar drop indicator.
    ///   - tabIds: Visible workspace row identifiers in display order.
    /// - Returns: `true` when the resolved indicator targets this row's top edge.
    public func topVisible(
        forTabId tabId: UUID,
        draggedTabId: UUID?,
        dropIndicator: SidebarDropIndicator?,
        tabIds: [UUID]
    ) -> Bool {
        guard draggedTabId != nil, let indicator = dropIndicator else { return false }
        return tabIds.contains(tabId) && indicator.tabId == tabId && indicator.edge == .top
    }

    /// Returns whether the bottom-edge indicator should render below a row.
    ///
    /// - Parameters:
    ///   - tabId: The row currently being rendered.
    ///   - draggedTabId: The workspace currently being dragged, if any.
    ///   - dropIndicator: The resolved sidebar drop indicator.
    ///   - tabIds: Visible workspace row identifiers in display order.
    /// - Returns: `true` when the resolved indicator targets this row's bottom edge.
    public func bottomVisible(
        forTabId tabId: UUID,
        draggedTabId: UUID?,
        dropIndicator: SidebarDropIndicator?,
        tabIds: [UUID]
    ) -> Bool {
        guard draggedTabId != nil, let indicator = dropIndicator else { return false }
        return tabIds.contains(tabId) && indicator.tabId == tabId && indicator.edge == .bottom
    }

    /// Convenience used by `SidebarEmptyArea`: the empty area's "top" indicator
    /// (drawn above the empty space below all rows) is visible when the drop
    /// indicator targets nothing (end-of-list).
    public func emptyAreaTopVisible(
        draggedTabId: UUID?,
        dropIndicator: SidebarDropIndicator?,
        lastTabId: UUID?
    ) -> Bool {
        guard draggedTabId != nil, let indicator = dropIndicator else { return false }
        return indicator.tabId == nil
    }
}
