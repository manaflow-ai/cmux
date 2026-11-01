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
/// Differences: a pinned tab keeps its centered icon on hover and never shows
/// an x; it closes from its right-click menu (Lawrence msg 19392: "hover on
/// pinned tab should not have close button, should only be able to close in
/// right click"; takes back HQ #4743's hover swap). A crowded inactive tab
/// swaps its centered icon for the x on hover until both the icon and the x
/// fit; the icon stays put when both fit (nxdog9, Lawrence 2026-10-20).
/// A selected tab keeps its existing close once it is narrower than Chromium's
/// close-button threshold, where the x costs no title text.
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
            // The pinned icon owns the one centered slot, hovered or not: no x (Lawrence msg 19392).
            return TabChromeVisibility(showsIcon: true, showsTitle: false, showsClose: false, centersContent: true)
        }
        // Narrower than an icon-only tab (Chrome's inactive minimum, 32; an opening or closing tab): nothing
        // shows. Not the strip's crowding minimum, which keeps a title (cx-kp9b4) and in Scroll mode is 140.
        if width + 0.5 < min(metrics.minInactiveTabWidth, metrics.chrome.minInactiveWidth) { return .hidden }
        let contents = width - metrics.contentLeadingInset - metrics.contentTrailingInset
        let roomy = contents >= metrics.closeMinContentsWidth
        let wantsClose: Bool
        switch style {
        // Inactive crowded tabs put the close in the icon's center on hover.
        // Once there is room for both, the icon keeps its original position.
        // The selected tab's existing at-rest narrow close is preserved.
        case .chrome: wantsClose = isSelected ? (isHovered || !roomy) : isHovered
        case .compact: wantsClose = isHovered
        }
        // A tab that cannot close (Home's tab, `pinned-dock-v1`) never shows its x.
        let showsClose = wantsClose && isClosable
        var available = contents
        if showsClose { available -= metrics.closeButtonSize + metrics.titleCloseSpacing }
        // When the x leaves no room, it takes the centered icon slot
        // (including a hovered crowded inactive tab). With no x, the icon stays.
        let iconFits = available >= metrics.iconSize
        let showsIcon = iconFits || !showsClose
        let titleWidth = available - metrics.iconSize - metrics.iconTitleSpacing
        let showsTitle = iconFits && titleWidth >= metrics.titleMinVisibleWidth
        return TabChromeVisibility(showsIcon: showsIcon, showsTitle: showsTitle, showsClose: showsClose, centersContent: !showsTitle)
    }

    /// One close-button origin for the painted layer and the pre-hover AX target.
    /// When the icon yields its sole slot, the x is centered; with both visible,
    /// it remains in the trailing track. A hidden x has no origin.
    func closeButtonOriginX(pillWidth: CGFloat, metrics m: TabStripMetrics) -> CGFloat? {
        guard showsClose else { return nil }
        return showsIcon || !centersContent
            ? pillWidth - m.contentTrailingInset - m.closeButtonSize
            : (pillWidth - m.closeButtonSize) / 2
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
