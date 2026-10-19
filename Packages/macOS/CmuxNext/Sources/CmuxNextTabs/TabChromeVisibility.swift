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
public struct TabChromeVisibility: Hashable, Sendable {
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
        isClosable: Bool = true,
        style: TabStripStyle,
        metrics: TabStripMetrics = .standard
    ) -> TabChromeVisibility {
        if isPinned {
            return TabChromeVisibility(showsIcon: true, showsTitle: false, showsClose: false, centersContent: true)
        }
        // Narrower than an icon-only tab (Chrome's inactive minimum, 32; an opening or closing tab): nothing
        // shows. Not the strip's crowding minimum, which keeps a title (cx-kp9b4) and in Scroll mode is 140.
        if width + 0.5 < min(metrics.minInactiveTabWidth, metrics.chrome.minInactiveWidth) { return .hidden }
        let contents = width - metrics.contentLeadingInset - metrics.contentTrailingInset
        let roomy = contents >= metrics.closeMinContentsWidth
        let wantsClose: Bool
        switch style {
        case .chrome: wantsClose = isSelected ? (isHovered || !roomy) : (isHovered && roomy)
        case .compact: wantsClose = isHovered
        }
        // A tab that cannot close (Home's tab, `pinned-dock-v1`) never shows its x.
        let showsClose = wantsClose && isClosable
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

    /// The form at each width of a width path (an open, a close, a selection change, a reflow), from
    /// `start`, the form on screen when the path starts, to the rest form at the last width. Each of
    /// the icon, the x and the title changes at most once on the path, as the parts decided before it
    /// leave room: a part both ends agree on keeps that state at every width, and a part that changes
    /// switches at the first width from which the rules keep it in its end state through the end. The
    /// x is decided first (as at rest), but a tab that keeps its icon shows its x only where both fit,
    /// so a crowded tab that gains the selection keeps its icon and gains the x once there is room
    /// (never the x centered first and the icon after it: a motion reversal).
    public static func path(
        widths: [CGFloat],
        from start: TabChromeVisibility,
        isPinned: Bool,
        isSelected: Bool,
        isHovered: Bool,
        isClosable: Bool = true,
        style: TabStripStyle,
        metrics m: TabStripMetrics = .standard
    ) -> [TabChromeVisibility] {
        let rest = widths.map {
            resolve(width: $0, isPinned: isPinned, isSelected: isSelected, isHovered: isHovered, isClosable: isClosable,
                    style: style, metrics: m)
        }
        guard !isPinned, let end = rest.last else { return rest }
        let contents = widths.map { $0 - m.contentLeadingInset - m.contentTrailingInset }
        let shows = rest.map { $0 != .hidden }
        func available(_ index: Int, close: Bool) -> CGFloat {
            contents[index] - (close ? m.closeButtonSize + m.titleCloseSpacing : 0)
        }
        let keepsIcon = start.showsIcon && end.showsIcon
        // A width that springs past an end (bounce) or turns back (a retarget) can leave a kept icon no
        // room for the x for a few samples: the x waits there instead of covering the icon.
        let fits = rest.indices.map { !keepsIcon || available($0, close: true) >= m.iconSize }
        let close = zip(once(rest.indices.map { rest[$0].showsClose && fits[$0] }, from: start.showsClose), fits).map { $0 && $1 }
        let icon = once(rest.indices.map { index in
            shows[index] && (available(index, close: close[index]) >= m.iconSize || !close[index])
        }, from: start.showsIcon)
        let title = once(rest.indices.map { index in
            shows[index] && icon[index]
                && available(index, close: close[index]) - m.iconSize - m.iconTitleSpacing >= m.titleMinVisibleWidth
        }, from: start.showsTitle)
        return rest.indices.map { index in
            TabChromeVisibility(showsIcon: icon[index], showsTitle: title[index], showsClose: close[index], centersContent: !title[index])
        }
    }

    /// `wanted` (one value per sample) changed at most once from `start`: the end value from the first
    /// sample after the last one that wants otherwise.
    private static func once(_ wanted: [Bool], from start: Bool) -> [Bool] {
        guard let end = wanted.last else { return wanted }
        if start == end { return wanted.map { _ in end } }
        let first = (wanted.lastIndex { $0 != end } ?? -1) + 1
        return wanted.indices.map { $0 >= first ? end : start }
    }
}
