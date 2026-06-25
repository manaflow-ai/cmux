public import Foundation

/// Pure predicates deciding when a sidebar row (or the empty area below all
/// rows) should render its "top" drop indicator for a given drag state.
public struct SidebarTabDropIndicatorPredicate {
    public init() {}

    public func topVisible(
        forTabId tabId: UUID,
        draggedTabId: UUID?,
        dropIndicator: SidebarDropIndicator?,
        tabIds: [UUID],
        isExternalDragActive: Bool = false
    ) -> Bool {
        guard draggedTabId != nil || isExternalDragActive,
              let indicator = dropIndicator else { return false }
        if indicator.tabId == tabId && indicator.edge == .top {
            return true
        }
        guard indicator.edge == .bottom,
              let currentIndex = tabIds.firstIndex(of: tabId),
              currentIndex > 0
        else {
            return false
        }
        return tabIds[currentIndex - 1] == indicator.tabId
    }

    /// Convenience used by `SidebarEmptyArea`: the empty area's "top" indicator
    /// (drawn above the empty space below all rows) is visible when the drop
    /// indicator targets nothing (end-of-list) or the bottom edge of the last
    /// row.
    public func emptyAreaTopVisible(
        draggedTabId: UUID?,
        dropIndicator: SidebarDropIndicator?,
        lastTabId: UUID?,
        isExternalDragActive: Bool = false
    ) -> Bool {
        guard draggedTabId != nil || isExternalDragActive,
              let indicator = dropIndicator else { return false }
        if indicator.tabId == nil {
            return true
        }
        guard indicator.edge == .bottom, let lastTabId else { return false }
        return indicator.tabId == lastTabId
    }
}
