public import CoreGraphics

/// Which parts of a tab are visible at a given width and state.
///
/// Chromium's rules (`Tab::UpdateIconVisibility` and
/// `Tab::Layout`, plans/cmux-next/tabs.md), decided from the contents
/// width, the tab less both content insets:
/// - an inactive tab shows its icon while it fits, else centers it; its
///   title shows in whatever is left after the icon (faded, no ellipsis);
/// - the selected tab places its x first, then the icon if it fits, then
///   the title, so a narrow selected tab is icon and x only;
/// - a tab narrower than the minimum inactive width (closing, growing in)
///   shows nothing.
/// One difference: the x shows only on the hovered tab (nxdog9). The
/// selected tab also keeps it once its contents are narrower than Chromium's
/// close-button threshold, where it costs no title text.
public struct TabChromeVisibility: Equatable, Sendable {
    public var showsIcon: Bool
    public var showsTitle: Bool
    public var showsClose: Bool
    /// Icon (or the close button when it replaces the icon) is centered.
    public var centersContent: Bool

    static let hidden = TabChromeVisibility(showsIcon: false, showsTitle: false, showsClose: false, centersContent: true)

    public static func resolve(
        width: CGFloat,
        isPinned: Bool,
        isSelected: Bool,
        isHovered: Bool,
        style: TabStripStyle,
        metrics: TabStripMetrics = .standard
    ) -> TabChromeVisibility {
        if isPinned {
            return TabChromeVisibility(showsIcon: true, showsTitle: false, showsClose: false, centersContent: true)
        }
        if width + 0.5 < metrics.minInactiveTabWidth { return .hidden }
        let contents = width - metrics.contentLeadingInset - metrics.contentTrailingInset
        let roomy = contents >= metrics.closeMinContentsWidth
        let showsClose: Bool
        switch style {
        case .chrome: showsClose = isSelected ? (isHovered || !roomy) : (isHovered && roomy)
        case .compact: showsClose = isHovered
        }
        var available = contents
        if showsClose { available -= metrics.closeButtonSize + metrics.titleCloseSpacing }
        // The selected tab drops its icon when the x leaves no room;
        // an inactive tab centers its icon instead (it has no x then).
        let iconFits = available >= metrics.iconSize
        let showsIcon = iconFits || !showsClose
        let titleWidth = available - metrics.iconSize - metrics.iconTitleSpacing
        let showsTitle = iconFits && titleWidth >= metrics.titleMinVisibleWidth
        return TabChromeVisibility(showsIcon: showsIcon, showsTitle: showsTitle, showsClose: showsClose, centersContent: !showsTitle)
    }
}
