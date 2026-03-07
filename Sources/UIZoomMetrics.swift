import CoreGraphics
import Foundation

enum UIZoomMetrics {
    static let appStorageKey = "uiZoomScale"
    static let defaultScale: Double = 1.0
    static let minimumScale: Double = 0.5
    static let maximumScale: Double = 2.0
    static let step: Double = 0.1

    static func clamped(_ scale: Double) -> Double {
        min(maximumScale, max(minimumScale, scale))
    }

    static func effectiveScale() -> Double {
        let scale = UserDefaults.standard.double(forKey: appStorageKey)
        return scale == 0 ? defaultScale : scale
    }

    // MARK: - Sidebar Typography

    static func titleFontSize(_ scale: Double) -> CGFloat { 12.5 * scale }
    static func subtitleFontSize(_ scale: Double) -> CGFloat { 10 * scale }
    static func smallFontSize(_ scale: Double) -> CGFloat { 9 * scale }
    static func tinyFontSize(_ scale: Double) -> CGFloat { 8 * scale }
    static func separatorDotFontSize(_ scale: Double) -> CGFloat { 3 * scale }

    // MARK: - Sidebar Element sizes

    static func badgeSize(_ scale: Double) -> CGFloat { 16 * scale }
    static func closeButtonSize(_ scale: Double) -> CGFloat { 16 * scale }
    static func progressBarHeight(_ scale: Double) -> CGFloat { 3 * scale }
    static func leadingRailWidth(_ scale: Double) -> CGFloat { 3 * scale }
    static func dropIndicatorHeight(_ scale: Double) -> CGFloat { 2 * scale }

    // MARK: - Sidebar Spacing

    static func contentSpacing(_ scale: Double) -> CGFloat { 4 * scale }
    static func headerSpacing(_ scale: Double) -> CGFloat { 8 * scale }
    static func logEntrySpacing(_ scale: Double) -> CGFloat { 4 * scale }
    static func progressSpacing(_ scale: Double) -> CGFloat { 2 * scale }
    static func branchLineSpacing(_ scale: Double) -> CGFloat { 1 * scale }
    static func branchItemSpacing(_ scale: Double) -> CGFloat { 3 * scale }
    static func pullRequestRowSpacing(_ scale: Double) -> CGFloat { 1 * scale }
    static func pullRequestItemSpacing(_ scale: Double) -> CGFloat { 4 * scale }
    static func tabRowSpacing(_ scale: Double) -> CGFloat { 2 * scale }

    // MARK: - Sidebar Padding

    static func horizontalPadding(_ scale: Double) -> CGFloat { 10 * scale }
    static func verticalPadding(_ scale: Double) -> CGFloat { 8 * scale }
    static func outerHorizontalPadding(_ scale: Double) -> CGFloat { 6 * scale }
    static func listVerticalPadding(_ scale: Double) -> CGFloat { 8 * scale }
    static func shortcutHintHorizontalPadding(_ scale: Double) -> CGFloat { 6 * scale }
    static func shortcutHintVerticalPadding(_ scale: Double) -> CGFloat { 2 * scale }
    static func separatorDotHorizontalPadding(_ scale: Double) -> CGFloat { 1 * scale }
    static func dropIndicatorHorizontalPadding(_ scale: Double) -> CGFloat { 8 * scale }
    static func leadingRailLeadingPadding(_ scale: Double) -> CGFloat { 4 * scale }
    static func leadingRailVerticalPadding(_ scale: Double) -> CGFloat { 5 * scale }

    // MARK: - Sidebar Corner radius

    static func cornerRadius(_ scale: Double) -> CGFloat { 6 * scale }

    // MARK: - Sidebar Container

    static func trafficLightPadding(_ scale: Double) -> CGFloat { 28 * scale }
    static func topScrimExtraHeight(_ scale: Double) -> CGFloat { 20 * scale }

    // MARK: - Minimum sidebar width

    static let baseMinimumSidebarWidth: Double = 186

    static func minimumSidebarWidth(_ scale: Double) -> Double {
        baseMinimumSidebarWidth * clamped(scale)
    }

    // MARK: - Titlebar

    static func titlebarFontSize(_ scale: Double) -> CGFloat { 13 * scale }
    static func titlebarHeight(_ scale: Double) -> CGFloat { 28 * scale }
    static func titlebarTopPadding(_ scale: Double) -> CGFloat { 2 * scale }
    static func titlebarHorizontalPadding(_ scale: Double) -> CGFloat { 8 * scale }
    static func titlebarDividerHeight(_ scale: Double) -> CGFloat { 1 * scale }

    // MARK: - Command Palette

    static func paletteListMaxHeight(_ scale: Double) -> CGFloat { 450 * scale }
    static func paletteRowHeight(_ scale: Double) -> CGFloat { 24 * scale }
    static func paletteEmptyStateHeight(_ scale: Double) -> CGFloat { 44 * scale }
    static func paletteFieldFontSize(_ scale: Double) -> CGFloat { 13 * scale }
    static func paletteFieldHPadding(_ scale: Double) -> CGFloat { 9 * scale }
    static func paletteFieldVPadding(_ scale: Double) -> CGFloat { 7 * scale }
    static func paletteResultFontSize(_ scale: Double) -> CGFloat { 13 * scale }
    static func paletteResultHPadding(_ scale: Double) -> CGFloat { 9 * scale }
    static func paletteResultVPadding(_ scale: Double) -> CGFloat { 2 * scale }
    static func paletteTrailingFontSize(_ scale: Double) -> CGFloat { 11 * scale }
    static func paletteTrailingHPadding(_ scale: Double) -> CGFloat { 4 * scale }
    static func paletteTrailingVPadding(_ scale: Double) -> CGFloat { 1 * scale }
    static func paletteTrailingCornerRadius(_ scale: Double) -> CGFloat { 4 * scale }

    // MARK: - Browser UI

    static func omnibarCornerRadius(_ scale: Double) -> CGFloat { 10 * scale }
    static func addressBarButtonSize(_ scale: Double) -> CGFloat { 22 * scale }
    static func addressBarButtonHitSize(_ scale: Double) -> CGFloat { 26 * scale }
    static func addressBarVPadding(_ scale: Double) -> CGFloat { 4 * scale }
    static func addressBarButtonFontSize(_ scale: Double) -> CGFloat { 12 * scale }
    static func addressBarHPadding(_ scale: Double) -> CGFloat { 8 * scale }
    static func devToolsIconSize(_ scale: Double) -> CGFloat { 11 * scale }
    static func popupCornerRadius(_ scale: Double) -> CGFloat { 12 * scale }
    static func popupRowHighlightRadius(_ scale: Double) -> CGFloat { 9 * scale }
    static func popupRowHeight(_ scale: Double) -> CGFloat { 24 * scale }
    static func popupRowSpacing(_ scale: Double) -> CGFloat { 1 * scale }
    static func popupMaxHeight(_ scale: Double) -> CGFloat { 560 * scale }

    // MARK: - Search Overlay

    static func searchFieldWidth(_ scale: Double) -> CGFloat { 180 * scale }
    static func searchFieldLPadding(_ scale: Double) -> CGFloat { 8 * scale }
    static func searchFieldRPadding(_ scale: Double) -> CGFloat { 50 * scale }
    static func searchFieldVPadding(_ scale: Double) -> CGFloat { 6 * scale }
    static func searchFieldCornerRadius(_ scale: Double) -> CGFloat { 6 * scale }
    static func searchContainerCornerRadius(_ scale: Double) -> CGFloat { 8 * scale }
    static func searchContainerPadding(_ scale: Double) -> CGFloat { 8 * scale }
    static func searchSpacing(_ scale: Double) -> CGFloat { 4 * scale }
    static func searchCounterFontSize(_ scale: Double) -> CGFloat { 10 * scale }
    static func searchCounterTrailingPadding(_ scale: Double) -> CGFloat { 8 * scale }

    // MARK: - Notifications

    static func notificationContainerPadding(_ scale: Double) -> CGFloat { 16 * scale }
    static func notificationItemSpacing(_ scale: Double) -> CGFloat { 8 * scale }
    static func notificationItemHPadding(_ scale: Double) -> CGFloat { 16 * scale }
    static func notificationItemVPadding(_ scale: Double) -> CGFloat { 12 * scale }
    static func notificationHeaderFontSize(_ scale: Double) -> CGFloat { 10 * scale }
    static func notificationHeaderHPadding(_ scale: Double) -> CGFloat { 6 * scale }
    static func notificationHeaderVPadding(_ scale: Double) -> CGFloat { 2 * scale }

    // MARK: - Markdown Panel

    static func mdHeaderIconSize(_ scale: Double) -> CGFloat { 12 * scale }
    static func mdHeaderTextSize(_ scale: Double) -> CGFloat { 11 * scale }
    static func mdHeaderSpacing(_ scale: Double) -> CGFloat { 6 * scale }
    static func mdHeaderHPadding(_ scale: Double) -> CGFloat { 24 * scale }
    static func mdHeaderVPadding(_ scale: Double) -> CGFloat { 16 * scale }
    static func mdDividerHPadding(_ scale: Double) -> CGFloat { 16 * scale }
    static func mdContentHPadding(_ scale: Double) -> CGFloat { 24 * scale }
    static func mdContentVPadding(_ scale: Double) -> CGFloat { 16 * scale }

    // MARK: - Feedback Dialog

    static func feedbackDialogWidth(_ scale: Double) -> CGFloat { 520 * scale }
    static func feedbackDialogPadding(_ scale: Double) -> CGFloat { 20 * scale }
    static func feedbackFontSize(_ scale: Double) -> CGFloat { 12 * scale }
    static func feedbackSmallFontSize(_ scale: Double) -> CGFloat { 11 * scale }

    // MARK: - Workspace

    static func workspaceTitleFontSize(_ scale: Double) -> CGFloat { 11 * scale }
    static func workspaceTitleHPadding(_ scale: Double) -> CGFloat { 8 * scale }
    static func workspaceTitleVPadding(_ scale: Double) -> CGFloat { 3 * scale }
    static func emptyStateIconSize(_ scale: Double) -> CGFloat { 48 * scale }
    static func emptyStateSpacing(_ scale: Double) -> CGFloat { 16 * scale }

    // MARK: - Update UI

    static func updatePopoverWidth(_ scale: Double) -> CGFloat { 300 * scale }
    static func updatePopoverPadding(_ scale: Double) -> CGFloat { 16 * scale }
    static func updateTitleFontSize(_ scale: Double) -> CGFloat { 13 * scale }
    static func updateBodyFontSize(_ scale: Double) -> CGFloat { 11 * scale }
    static func updatePillSpacing(_ scale: Double) -> CGFloat { 6 * scale }
    static func updatePillIconSize(_ scale: Double) -> CGFloat { 14 * scale }
    static func updatePillHPadding(_ scale: Double) -> CGFloat { 8 * scale }
    static func updatePillVPadding(_ scale: Double) -> CGFloat { 4 * scale }
}
