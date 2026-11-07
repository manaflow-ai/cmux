import SwiftUI

/// Layout for the tab-search field pinned under the sidebar titlebar strip.
extension VerticalTabsSidebar {
    /// Gap from the titlebar strip to the top of the pinned
    /// ``SidebarTabSearchView`` field. The first workspace row's own top
    /// padding (`SidebarWorkspaceListMetrics.rowVerticalPadding`) provides the
    /// matching gap below the field, so top and bottom read as equal.
    static let sidebarTabSearchFieldTopGap: CGFloat = 8
    /// Total band reserved under the titlebar strip for the field, so the
    /// first workspace row sits flush below it.
    static let sidebarTabSearchBandHeight: CGFloat = sidebarTabSearchFieldTopGap + SidebarTabSearchView.fieldHeight
    /// Breathing room kept between the tab-search dropdown and the sidebar's
    /// bottom edge.
    private static let sidebarTabSearchDropdownBottomMargin: CGFloat = 12

    /// Workspace-list scroll insets with the search band folded into `top`, so
    /// the first-row offset, reorder drop zone, and content-height math stay
    /// consistent in one place.
    static var sidebarTabSearchScrollInsets: SidebarWorkspaceScrollInsets {
        SidebarWorkspaceScrollInsets(
            top: MinimalModeChromeMetrics.titlebarHeight + sidebarTabSearchBandHeight,
            bottom: SidebarWorkspaceScrollInsets.workspaceList.bottom
        )
    }

    /// The pinned search field, padded below the draggable titlebar strip and
    /// window controls. Apply it after the scroll fade `.mask(...)` so the fade
    /// never dims the field.
    ///
    /// - Parameter viewportHeight: The sidebar viewport height, a downward-only
    ///   layout input (never written back into state).
    func sidebarTabSearchOverlay(viewportHeight: CGFloat) -> some View {
        SidebarTabSearchView(
            source: sidebarTabSearchSource,
            focusTargetWindow: observedWindow,
            availableDropdownHeight: Self.sidebarTabSearchAvailableDropdownHeight(viewportHeight: viewportHeight)
        )
        .padding(.top, MinimalModeChromeMetrics.titlebarHeight + Self.sidebarTabSearchFieldTopGap)
        .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// Room left below the search field inside the sidebar. Caps the dropdown
    /// so its lower rows never land past the sidebar edge where scrolling can't
    /// reveal them. Zero until the viewport is measured.
    static func sidebarTabSearchAvailableDropdownHeight(viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight > 0 else { return 0 }
        let consumed = MinimalModeChromeMetrics.titlebarHeight
            + sidebarTabSearchBandHeight
            + sidebarTabSearchDropdownBottomMargin
        return max(0, viewportHeight - consumed)
    }
}
