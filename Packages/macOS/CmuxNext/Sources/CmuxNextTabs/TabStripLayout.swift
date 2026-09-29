public import CoreGraphics

/// Every size the strip uses. Pure data so layout math is testable.
public struct TabStripMetrics: Equatable, Sendable {
    /// Widest an unpinned tab gets (Chrome's standard width).
    public var maxTabWidth: CGFloat = 240
    /// Narrowest an inactive tab gets before the strip starts to scroll.
    public var minInactiveTabWidth: CGFloat = 40
    /// The selected tab never gets narrower than this, so it keeps room for
    /// its close button while the others shrink to icons.
    public var minActiveTabWidth: CGFloat = 56
    public var pinnedTabWidth: CGFloat = 40
    /// Width of every unpinned tab in `.compact` style.
    public var compactTabWidth: CGFloat = 160
    /// Extra space between the last pinned tab and the first unpinned tab.
    public var pinnedGroupGap: CGFloat = 6

    /// Inactive, unhovered tabs show a close button only when at least this wide.
    public var inactiveCloseMinWidth: CGFloat = 100
    /// Hovered inactive tabs show a close button only when at least this wide.
    public var hoverCloseMinWidth: CGFloat = 36
    /// Below this width the title is hidden entirely.
    public var titleMinWidth: CGFloat = 60

    public var contentLeadingInset: CGFloat = 10
    public var contentTrailingInset: CGFloat = 6
    public var iconSize: CGFloat = 16
    public var closeButtonSize: CGFloat = 18
    public var iconTitleSpacing: CGFloat = 6
    public var titleCloseSpacing: CGFloat = 4
    /// Length of the gradient that fades a clipped title.
    public var titleFadeWidth: CGFloat = 22

    /// Horizontal inset of the strip content from its bounds.
    public var stripHorizontalPadding: CGFloat = 4
    public var stripVerticalPadding: CGFloat = 4
    public var newTabButtonWidth: CGFloat = 30
    /// Length of the fade on a scrolled edge.
    public var scrollFadeWidth: CGFloat = 24
    /// Inset of the tab background from the tab frame, so neighbors read as separate.
    public var tabBackgroundInset: CGFloat = 1.5
    /// Vertical distance outside the strip that tears a dragged tab out.
    public var tearOffDistance: CGFloat = 22

    public init() {}

    public static let standard = TabStripMetrics()
}

/// One tab as layout sees it.
public struct TabLayoutItem: Equatable, Sendable {
    public var id: TabID
    public var isPinned: Bool
    public var isSelected: Bool

    public init(id: TabID, isPinned: Bool = false, isSelected: Bool = false) {
        self.id = id
        self.isPinned = isPinned
        self.isSelected = isSelected
    }
}

/// A laid out tab, in content coordinates (0 is the leading edge of the first tab).
public struct TabLayoutSlot: Equatable, Sendable {
    public var id: TabID
    public var x: CGFloat
    public var width: CGFloat
    public var isPinned: Bool

    public var maxX: CGFloat { x + width }
}

public struct TabLayoutResult: Equatable, Sendable {
    public var slots: [TabLayoutSlot]
    /// Total width of all tabs, including the pinned group gap.
    public var contentWidth: CGFloat
    /// Width given to an inactive unpinned tab (0 when there are none).
    public var standardWidth: CGFloat
    /// The width tabs were allowed to fill.
    public var availableWidth: CGFloat

    public var isOverflowing: Bool { contentWidth > availableWidth + 0.5 }

    public func slot(_ id: TabID) -> TabLayoutSlot? {
        slots.first { $0.id == id }
    }
}

/// Pure tab geometry. The view diffs successive results and animates between them.
public enum TabLayoutEngine {
    /// Lays out `items` in order.
    ///
    /// - Parameter closingModeWidth: Chrome's deferred relayout. While the user
    ///   closes tabs with the mouse, the strip pretends to be only this wide so
    ///   the remaining tabs keep their width and the next close button slides
    ///   under the pointer. Nil outside closing mode.
    public static func layout(
        items: [TabLayoutItem],
        availableWidth: CGFloat,
        style: TabStripStyle,
        metrics: TabStripMetrics = .standard,
        closingModeWidth: CGFloat? = nil
    ) -> TabLayoutResult {
        let available = max(0, min(availableWidth, closingModeWidth ?? .infinity))
        let pinnedCount = items.count(where: \.isPinned)
        let unpinned = items.filter { !$0.isPinned }
        let gap = (pinnedCount > 0 && !unpinned.isEmpty) ? metrics.pinnedGroupGap : 0
        let pinnedTotal = CGFloat(pinnedCount) * metrics.pinnedTabWidth + gap
        let unpinnedWidths = unpinnedTabWidths(
            unpinned,
            available: max(0, available - pinnedTotal),
            style: style,
            metrics: metrics
        )

        var slots: [TabLayoutSlot] = []
        slots.reserveCapacity(items.count)
        var x: CGFloat = 0
        var unpinnedIndex = 0
        var previousWasPinned = false
        for item in items {
            if !item.isPinned, previousWasPinned { x += metrics.pinnedGroupGap }
            let width: CGFloat
            if item.isPinned {
                width = metrics.pinnedTabWidth
            } else {
                width = unpinnedWidths.widths[unpinnedIndex]
                unpinnedIndex += 1
            }
            slots.append(TabLayoutSlot(id: item.id, x: x, width: width, isPinned: item.isPinned))
            x += width
            previousWasPinned = item.isPinned
        }
        return TabLayoutResult(
            slots: slots,
            contentWidth: x,
            standardWidth: unpinnedWidths.standard,
            availableWidth: available
        )
    }

    private static func unpinnedTabWidths(
        _ tabs: [TabLayoutItem],
        available: CGFloat,
        style: TabStripStyle,
        metrics: TabStripMetrics
    ) -> (widths: [CGFloat], standard: CGFloat) {
        let count = tabs.count
        guard count > 0 else { return ([], 0) }
        if style == .compact {
            return (Array(repeating: metrics.compactTabWidth, count: count), metrics.compactTabWidth)
        }

        let ideal = available / CGFloat(count)
        if ideal >= metrics.maxTabWidth {
            return (Array(repeating: metrics.maxTabWidth, count: count), metrics.maxTabWidth)
        }
        if ideal >= metrics.minActiveTabWidth {
            let widths = distribute(available, count: count)
            return (widths, widths.last ?? 0)
        }

        // Too narrow for everyone: the selected tab keeps its minimum and the
        // rest share what is left, down to the inactive minimum (then scroll).
        guard let selectedIndex = tabs.firstIndex(where: \.isSelected), count > 1 else {
            let width = max(ideal.rounded(.down), metrics.minInactiveTabWidth)
            let clamped = count == 1 ? max(width, metrics.minActiveTabWidth) : width
            return (Array(repeating: clamped, count: count), clamped)
        }
        let othersAvailable = available - metrics.minActiveTabWidth
        let perOther = othersAvailable / CGFloat(count - 1)
        var others: [CGFloat]
        if perOther >= metrics.minInactiveTabWidth {
            others = distribute(othersAvailable, count: count - 1)
        } else {
            others = Array(repeating: metrics.minInactiveTabWidth, count: count - 1)
        }
        let standard = others.last ?? metrics.minInactiveTabWidth
        others.insert(metrics.minActiveTabWidth, at: selectedIndex)
        return (others, standard)
    }

    /// Splits `total` into `count` whole-point widths. Leftover points go to
    /// the leading tabs, as Chrome does, so the strip edge stays crisp.
    static func distribute(_ total: CGFloat, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let base = (total / CGFloat(count)).rounded(.down)
        let extra = max(0, min(count, Int((total - base * CGFloat(count)).rounded(.down))))
        return (0..<count).map { $0 < extra ? base + 1 : base }
    }

    /// The closing-mode width after the user closes `closing` with the mouse.
    ///
    /// Closing any tab except the last shrinks the pretend strip width by the
    /// closed tab, so every other tab keeps its width and the right neighbor
    /// slides under the pointer. Closing the last tab keeps the previous value,
    /// so the remaining tabs may grow back toward the pointer.
    public static func closingModeWidth(
        afterClosing closing: TabID,
        in result: TabLayoutResult,
        current: CGFloat?
    ) -> CGFloat? {
        guard let index = result.slots.firstIndex(where: { $0.id == closing }),
              result.slots.count > 1,
              index < result.slots.count - 1,
              let last = result.slots.last
        else { return current }
        var width = last.maxX - result.slots[index].width
        let closed = result.slots[index]
        let pinnedCount = result.slots.count(where: \.isPinned)
        let hasUnpinned = result.slots.contains { !$0.isPinned }
        if closed.isPinned, pinnedCount == 1, hasUnpinned {
            // The pinned group disappears, and its gap with it.
            width -= result.slots[index + 1].x - closed.maxX
        }
        return current.map { min($0, width) } ?? width
    }
}

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
        let showsClose: Bool
        switch style {
        case .chrome:
            if isSelected {
                showsClose = true
            } else if isHovered {
                showsClose = width >= metrics.hoverCloseMinWidth
            } else {
                showsClose = width >= metrics.inactiveCloseMinWidth
            }
        case .compact:
            showsClose = isSelected || isHovered
        }
        let inner = width - metrics.contentLeadingInset - metrics.contentTrailingInset
        let iconAndClose = metrics.iconSize + metrics.titleCloseSpacing + metrics.closeButtonSize
        let showsIcon = !(showsClose && inner < iconAndClose)
        let showsTitle = width >= metrics.titleMinWidth && showsIcon
        let centers = !showsTitle
        return TabChromeVisibility(showsIcon: showsIcon, showsTitle: showsTitle, showsClose: showsClose, centersContent: centers)
    }
}

/// Drag reorder math.
public enum TabReorderMath {
    /// Index at which a dragged tab lands among `otherWidths` (the tabs of its
    /// group in order, without the dragged tab). Picks the slot whose leading
    /// edge is nearest to the dragged tab's leading edge.
    public static func insertionIndex(draggedMinX: CGFloat, groupStart: CGFloat, otherWidths: [CGFloat]) -> Int {
        var best = 0
        var bestDistance = CGFloat.infinity
        var edge = groupStart
        for index in 0...otherWidths.count {
            let distance = abs(edge - draggedMinX)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
            if index < otherWidths.count { edge += otherWidths[index] }
        }
        return best
    }
}

/// Horizontal overflow scrolling math.
public enum TabScrollMath {
    public static func maxOffset(contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        max(0, contentWidth - viewportWidth)
    }

    public static func clamp(_ offset: CGFloat, contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        min(max(0, offset), maxOffset(contentWidth: contentWidth, viewportWidth: viewportWidth))
    }

    /// The smallest scroll change that shows `slot` fully, keeping `margin`
    /// (the fade width) between it and a scrolled edge.
    public static func offset(
        revealing slot: TabLayoutSlot,
        current: CGFloat,
        contentWidth: CGFloat,
        viewportWidth: CGFloat,
        margin: CGFloat
    ) -> CGFloat {
        var offset = current
        let leading = slot.x - (slot.x > 0 ? margin : 0)
        let trailing = slot.maxX + (slot.maxX < contentWidth ? margin : 0)
        if trailing - offset > viewportWidth { offset = trailing - viewportWidth }
        if leading < offset { offset = leading }
        return clamp(offset, contentWidth: contentWidth, viewportWidth: viewportWidth)
    }

    /// Which edges show a fade for a scroll offset.
    public static func fadedEdges(offset: CGFloat, contentWidth: CGFloat, viewportWidth: CGFloat) -> (leading: Bool, trailing: Bool) {
        let maximum = maxOffset(contentWidth: contentWidth, viewportWidth: viewportWidth)
        return (offset > 0.5, offset < maximum - 0.5)
    }
}
