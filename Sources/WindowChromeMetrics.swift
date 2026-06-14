import CoreGraphics

enum WindowChromeMetrics {
    static let sharedChromeBarHeight: CGFloat = 28
    static let appTitlebarHeight: CGFloat = sharedChromeBarHeight
    static let bonsplitTabBarHeight: CGFloat = sharedChromeBarHeight
    static let secondaryTitlebarHeight: CGFloat = sharedChromeBarHeight
    static let minimumTitlebarHeight: CGFloat = sharedChromeBarHeight
    static let maximumTitlebarHeight: CGFloat = 72
    static let defaultTitlebarHeight: CGFloat = sharedChromeBarHeight

    static func clampedTitlebarHeight(_ height: CGFloat) -> CGFloat {
        max(minimumTitlebarHeight, min(maximumTitlebarHeight, height))
    }
}

enum MinimalModeChromeMetrics {
    static let titlebarHeight: CGFloat = WindowChromeMetrics.appTitlebarHeight
}

enum HeaderChromeControlMetrics {
    static let buttonSize: CGFloat = 20
    static let iconSize: CGFloat = 12
    static let iconFrameSize: CGFloat = 14
    static let cornerRadius: CGFloat = 6
    static let titlebarControlsLeadingPadding: CGFloat = 4

    static func iconFrameSize(forIconSize iconSize: CGFloat) -> CGFloat {
        max(Self.iconFrameSize, iconSize + 2)
    }
}

enum RightSidebarChromeMetrics {
    static let titlebarHeight: CGFloat = WindowChromeMetrics.appTitlebarHeight
    static let secondaryBarHeight: CGFloat = WindowChromeMetrics.secondaryTitlebarHeight
    static let barHorizontalPadding: CGFloat = 8
    static let barVerticalPadding: CGFloat = 4
    static let controlHeight: CGFloat = secondaryBarHeight - (barVerticalPadding * 2)
    static let controlHorizontalPadding: CGFloat = 8
    static let controlCornerRadius: CGFloat = 5
    static let headerControlSize: CGFloat = HeaderChromeControlMetrics.buttonSize
    static let headerIconSize: CGFloat = 10
    static let headerIconFrameSize: CGFloat = headerIconSize
    static let headerControlSpacing: CGFloat = 4
    static let headerControlCornerRadius: CGFloat = HeaderChromeControlMetrics.cornerRadius
    static let headerControlCenterAlignmentAdjustment: CGFloat = 0
}

enum SidebarWorkspaceListMetrics {
    static let firstRowTopOffset: CGFloat = MinimalModeChromeMetrics.titlebarHeight + 2
    static let rowVerticalPadding: CGFloat = 8
    static let topScrimHeight: CGFloat = firstRowTopOffset + 20
    static let bottomScrimHeight: CGFloat = topScrimHeight

    static var scrollTopInset: CGFloat {
        max(0, firstRowTopOffset - rowVerticalPadding)
    }
}

struct SidebarWorkspaceScrollInsets: Equatable {
    static let workspaceList = SidebarWorkspaceScrollInsets(
        top: SidebarWorkspaceListMetrics.scrollTopInset,
        bottom: SidebarWorkspaceListMetrics.bottomScrimHeight
    )

    let top: CGFloat
    let bottom: CGFloat

    nonisolated var total: CGFloat {
        top + bottom
    }
}

enum SidebarWorkspaceScrollLayout {
    nonisolated static func contentMinHeight(
        viewportHeight: CGFloat,
        insets: SidebarWorkspaceScrollInsets
    ) -> CGFloat {
        // Floor the available height to a whole point. The scroll content is
        // sized to fill exactly `viewportHeight - insets.total`, but on
        // Retina/scaled displays the viewport is frequently fractional and
        // AppKit aligns the laid-out document view's frame to the backing store
        // (rounding up), so a fractional value can land just past the viewport.
        // That sub-point overflow makes the content barely scrollable and shows
        // the auto-hiding overlay scroller even with a single workspace.
        // Flooring to a whole point keeps `content + insets <= viewportHeight`
        // regardless of the display's backing scale, so the phantom scrollbar
        // stays hidden when content fits
        // (https://github.com/manaflow-ai/cmux/issues/3241).
        return max(0, (viewportHeight - insets.total).rounded(.down))
    }

    /// Height of the empty drop/tap area `SidebarRowsFillLayout` places below the
    /// last workspace row: the space remaining in the layout's concrete container.
    ///
    /// The container height is the viewport floor (`.frame(minHeight:)`) when the
    /// rows fit, or the rows' natural height when they overflow it. Because it is
    /// derived from the layout's own bounds rather than a measured whole-content
    /// height, the rows are never read into SwiftUI `@State` — which is what fed
    /// the relayout loop
    /// (https://github.com/manaflow-ai/cmux/issues/2586,
    /// https://github.com/manaflow-ai/cmux/issues/5764). When the rows fit, rows +
    /// empty area exactly fill the viewport, so there is no overflow and the
    /// overlay scroller stays hidden (https://github.com/manaflow-ai/cmux/issues/3241);
    /// when the rows overflow, this is `0` and the document view genuinely scrolls.
    ///
    /// - Parameters:
    ///   - containerHeight: The layout's resolved container height.
    ///   - rowsHeight: The rows' natural height.
    /// - Returns: The non-negative height for the empty area.
    nonisolated static func emptyAreaFillHeight(
        containerHeight: CGFloat,
        rowsHeight: CGFloat
    ) -> CGFloat {
        return max(0, containerHeight - rowsHeight)
    }

    /// Empty-area height from the explicit viewport, the way `SidebarRowsFillLayout`
    /// computes it. The container is the viewport when the rows fit, or the rows'
    /// height when they overflow it, so the empty area fills the remaining
    /// viewport below the rows (keeping the blank area a drop/tap target) and
    /// collapses to `0` once the rows overflow. Driven by the explicit viewport,
    /// not a layout proposal — a vertical `ScrollView` leaves the scroll-axis
    /// height unspecified, so deriving it from the proposal would collapse the
    /// area to a placeholder height when the rows fit.
    ///
    /// - Parameters:
    ///   - viewportHeight: The floored viewport height available to the content.
    ///   - rowsHeight: The rows' natural height.
    /// - Returns: The non-negative height for the empty area.
    nonisolated static func emptyAreaFillHeight(
        viewportHeight: CGFloat,
        rowsHeight: CGFloat
    ) -> CGFloat {
        return emptyAreaFillHeight(
            containerHeight: max(viewportHeight, rowsHeight),
            rowsHeight: rowsHeight
        )
    }
}
