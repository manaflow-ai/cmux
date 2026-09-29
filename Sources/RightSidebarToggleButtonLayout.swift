import CmuxSettings
import CoreGraphics

/// Resolves where the persistent right-sidebar button renders for one window
/// state, and which chrome must make room for it.
///
/// Every host (window corner, pane tab bar, left sidebar footer, right
/// sidebar mode bar) reads the same resolution, so each window shows exactly
/// one persistent button for the chosen placement.
struct RightSidebarToggleButtonLayout: Equatable {
    /// Side length of the button's hit area. Matches the mode bar controls.
    static let buttonSize: CGFloat = RightSidebarChromeMetrics.headerControlSize
    /// Distance from the button to the window or pane trailing edge. Matches
    /// the mode bar's trailing padding so the corner button sits exactly where
    /// the mode bar close button sits.
    static let trailingPadding: CGFloat = RightSidebarChromeMetrics.headerTrailingPadding
    /// Gap between the button and the tab bar action buttons before it.
    static let leadingGap: CGFloat = 4
    /// Width a tab bar reserves at its trailing end for the button.
    static let tabBarLaneWidth: CGFloat = leadingGap + buttonSize + trailingPadding

    /// Show the button in the window's top-trailing corner overlay.
    var showsCornerButton: Bool
    /// Show the button at the trailing end of the top-right pane's tab bar.
    var showsPaneTabBarButton: Bool
    /// Show the button at the trailing end of the left sidebar footer.
    var showsSidebarFooterButton: Bool
    /// Draw the mode bar close button with the sidebar glyph instead of an
    /// `xmark`, because it stands in for the corner button while shown.
    var modeBarCloseButtonUsesSidebarGlyph: Bool
    /// Width the top-right pane's tab bar reserves at its trailing end.
    var tabBarTrailingInset: CGFloat

    static func resolve(
        placement: RightSidebarToggleButtonPlacement,
        isMinimalMode: Bool,
        isRightSidebarVisible: Bool
    ) -> RightSidebarToggleButtonLayout {
        switch placement {
        case .titlebar:
            // While the sidebar is shown, its mode bar close button occupies
            // this exact corner position, so the corner button only renders
            // while the sidebar is hidden. Standard mode has a titlebar band
            // above the tab bars; minimal mode puts the top-right pane's tab
            // bar in the corner, so that tab bar must make room.
            return RightSidebarToggleButtonLayout(
                showsCornerButton: !isRightSidebarVisible,
                showsPaneTabBarButton: false,
                showsSidebarFooterButton: false,
                modeBarCloseButtonUsesSidebarGlyph: true,
                tabBarTrailingInset: isMinimalMode && !isRightSidebarVisible ? tabBarLaneWidth : 0
            )
        case .paneTabBar:
            return RightSidebarToggleButtonLayout(
                showsCornerButton: false,
                showsPaneTabBarButton: true,
                showsSidebarFooterButton: false,
                modeBarCloseButtonUsesSidebarGlyph: false,
                tabBarTrailingInset: tabBarLaneWidth
            )
        case .sidebarFooter:
            return RightSidebarToggleButtonLayout(
                showsCornerButton: false,
                showsPaneTabBarButton: false,
                showsSidebarFooterButton: true,
                modeBarCloseButtonUsesSidebarGlyph: false,
                tabBarTrailingInset: 0
            )
        case .hidden:
            return RightSidebarToggleButtonLayout(
                showsCornerButton: false,
                showsPaneTabBarButton: false,
                showsSidebarFooterButton: false,
                modeBarCloseButtonUsesSidebarGlyph: false,
                tabBarTrailingInset: 0
            )
        }
    }
}
