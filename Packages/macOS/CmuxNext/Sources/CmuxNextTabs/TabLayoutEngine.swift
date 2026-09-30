public import CoreGraphics

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
        // Chips and collapsed members have their own widths; the rest share.
        let flexible = unpinned.filter { $0.fixedWidth == nil && !$0.isCollapsed }
        let fixedTotal = unpinned.reduce(CGFloat(0)) { $0 + ($1.isCollapsed ? 0 : ($1.fixedWidth ?? 0)) }
        let gap = (pinnedCount > 0 && !unpinned.isEmpty) ? metrics.pinnedGroupGap : 0
        let pinnedTotal = CGFloat(pinnedCount) * metrics.pinnedTabWidth + gap
        let flexibleWidths = unpinnedTabWidths(
            flexible,
            available: max(0, available - pinnedTotal - fixedTotal),
            style: style,
            metrics: metrics
        )

        var slots: [TabLayoutSlot] = []
        slots.reserveCapacity(items.count)
        var x: CGFloat = 0
        var flexibleIndex = 0
        var previousWasPinned = false
        for item in items {
            if !item.isPinned, previousWasPinned { x += metrics.pinnedGroupGap }
            let width: CGFloat
            if item.isPinned {
                width = metrics.pinnedTabWidth
            } else if item.isCollapsed {
                width = 0
            } else if let fixed = item.fixedWidth {
                width = fixed
            } else {
                width = flexibleWidths.widths[flexibleIndex]
                flexibleIndex += 1
            }
            slots.append(TabLayoutSlot(
                id: item.id,
                x: x,
                width: width,
                isPinned: item.isPinned,
                groupID: item.groupID,
                isGroupChip: item.isGroupChip,
                isCollapsed: item.isCollapsed
            ))
            x += width
            previousWasPinned = item.isPinned
        }
        return TabLayoutResult(
            slots: slots,
            contentWidth: x,
            standardWidth: flexibleWidths.standard,
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
        guard total.isFinite, total > 0 else { return Array(repeating: 0, count: count) }
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
