public import Foundation

/// Pure predicates deciding when a sidebar row (or the empty area below all
/// rows) should render its drop indicator for a given drag state.
public struct SidebarTabDropIndicatorPredicate {
    /// Creates a sidebar drop-indicator predicate evaluator.
    public init() {}

    /// Returns whether the canonical gap indicator should render above a row.
    ///
    /// A resolved `.bottom` edge on the previous visible row represents the
    /// same visual divider as a `.top` edge on this row. The sidebar renders
    /// that divider only here, above the row after the gap, so adjacent rows
    /// cannot both draw competing drop lines.
    ///
    /// - Parameters:
    ///   - tabId: The row currently being rendered.
    ///   - draggedTabId: The workspace currently being dragged, if any.
    ///   - dropIndicator: The resolved sidebar drop indicator.
    ///   - tabIds: Visible workspace row identifiers in display order.
    /// - Returns: `true` when the resolved indicator targets the divider above this row.
    public func topVisible(
        forTabId tabId: UUID,
        draggedTabId: UUID?,
        dropIndicator: SidebarDropIndicator?,
        tabIds: [UUID]
    ) -> Bool {
        guard draggedTabId != nil,
              let indicator = dropIndicator,
              let rowIndex = tabIds.firstIndex(of: tabId) else { return false }

        switch indicator.edge {
        case .top:
            return indicator.tabId == tabId
        case .bottom:
            guard let indicatorTabId = indicator.tabId,
                  let indicatorIndex = tabIds.firstIndex(of: indicatorTabId) else {
                return false
            }
            return indicatorIndex + 1 == rowIndex
        }
    }

    /// Returns whether the bottom-edge indicator should render below a row.
    ///
    /// Row-to-row dividers are canonicalized to `topVisible` for the row after
    /// the gap. Root-level final append dividers are rendered by
    /// `emptyAreaTopVisible`; scoped group append dividers can be rendered below
    /// the last visible row in that group.
    ///
    /// - Parameters:
    ///   - tabId: The row currently being rendered.
    ///   - draggedTabId: The workspace currently being dragged, if any.
    ///   - dropIndicator: The resolved sidebar drop indicator.
    ///   - tabIds: Visible workspace row identifiers in display order.
    ///   - indicatorScope: The visible row scope where the resolved indicator is rendered.
    /// - Returns: `true` when a scoped final append divider should render below this row.
    public func bottomVisible(
        forTabId tabId: UUID,
        draggedTabId: UUID?,
        dropIndicator: SidebarDropIndicator?,
        tabIds: [UUID],
        indicatorScope: SidebarWorkspaceReorderDropIndicatorScope = .raw
    ) -> Bool {
        guard draggedTabId != nil,
              indicatorScope.isGroup,
              let indicator = dropIndicator,
              indicator.edge == .bottom,
              indicator.tabId == tabId,
              tabIds.last == tabId else {
            return false
        }
        return true
    }

    /// Convenience used by `SidebarEmptyArea`: the empty area's "top" indicator
    /// (drawn above the empty space below all rows) is visible when the drop
    /// indicator targets nothing (end-of-list), or when a `.bottom` indicator
    /// targets the last visible row in the current drag scope.
    ///
    /// - Parameters:
    ///   - draggedTabId: The workspace currently being dragged, if any.
    ///   - dropIndicator: The resolved sidebar drop indicator.
    ///   - lastTabId: The last visible row in the current root/top-level scope.
    ///   - indicatorScope: The visible row scope where the resolved indicator is rendered.
    /// - Returns: `true` when the root/top-level empty area should render its divider.
    public func emptyAreaTopVisible(
        draggedTabId: UUID?,
        dropIndicator: SidebarDropIndicator?,
        lastTabId: UUID?,
        indicatorScope: SidebarWorkspaceReorderDropIndicatorScope = .raw
    ) -> Bool {
        guard !indicatorScope.isGroup else { return false }
        guard draggedTabId != nil, let indicator = dropIndicator else { return false }
        if indicator.tabId == nil {
            return true
        }
        return indicator.edge == .bottom && indicator.tabId == lastTabId
    }
}
