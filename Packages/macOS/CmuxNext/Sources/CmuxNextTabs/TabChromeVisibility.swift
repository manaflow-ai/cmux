public import CoreGraphics

/// Which parts of a tab are visible at a given width and state.
public struct TabChromeVisibility: Equatable, Sendable {
    public var showsIcon: Bool
    public var showsTitle: Bool
    public var showsClose: Bool
    /// Icon (or the close button when it replaces the icon) is centered.
    public var centersContent: Bool

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
        // The x shows only on the hovered tab (user feedback, nxdog9), also
        // on the selected one. Close stays reachable by Cmd-W, middle-click,
        // the context menu, the palette and the CLI.
        let showsClose: Bool
        switch style {
        case .chrome:
            showsClose = isHovered && (isSelected || width >= metrics.hoverCloseMinWidth)
        case .compact:
            showsClose = isHovered
        }
        let inner = width - metrics.contentLeadingInset - metrics.contentTrailingInset
        let iconAndClose = metrics.iconSize + metrics.titleCloseSpacing + metrics.closeButtonSize
        let showsIcon = !(showsClose && inner < iconAndClose)
        let showsTitle = width >= metrics.titleMinWidth && showsIcon
        let centers = !showsTitle
        return TabChromeVisibility(showsIcon: showsIcon, showsTitle: showsTitle, showsClose: showsClose, centersContent: centers)
    }
}
