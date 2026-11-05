public import CoreGraphics

/// Pure tab geometry. The view diffs successive results and animates between them.
public struct TabLayoutEngine {
    public init() {}
    /// Lays out `items` in order.
    ///
    /// - Parameter closingModeWidth: the deferred relayout. While the user
    ///   closes tabs with the mouse, the strip pretends to be only this wide so
    ///   the remaining tabs keep their width and the next close button slides
    ///   under the pointer. Nil outside closing mode.
    /// - Parameter fullWidthTab: Full Width Tab mode (``TabStripModel/showsSelectedFullWidth``):
    ///   this tab fills the whole strip and every other item collapses to zero
    ///   width. Nil, or an id not in `items`, lays out every tab.
    public static func layout(
        items: [TabLayoutItem],
        availableWidth: CGFloat,
        style: TabStripStyle,
        metrics: TabStripMetrics = .standard,
        closingModeWidth: CGFloat? = nil,
        fullWidthTab: TabID? = nil
    ) -> TabLayoutResult {
        let available = max(0, min(availableWidth, closingModeWidth ?? .infinity))
        if let fullWidthTab, items.contains(where: { $0.id == fullWidthTab && !$0.isGroupChip }) {
            return fullWidthLayout(items: items, tab: fullWidthTab, available: available)
        }
        let pinnedCount = items.count(where: \.isPinned)
        let unpinned = items.filter { !$0.isPinned }
        // Chips and collapsed members have their own widths; the rest share.
        let flexible = unpinned.filter { $0.fixedWidth == nil && !$0.isCollapsed }
        let fixedTotal = unpinned.reduce(CGFloat(0)) { $0 + ($1.isCollapsed ? 0 : ($1.fixedWidth ?? 0)) }
        let gap = (pinnedCount > 0 && !unpinned.isEmpty) ? metrics.pinnedGroupGap : 0
        // One reserved total, as `resized` subtracts it, so both give the same share to the last bit.
        let reserved = CGFloat(pinnedCount) * metrics.pinnedTabWidth + gap + fixedTotal
        let share = rowShare(count: flexible.count, available: max(0, available - reserved), style: style, metrics: metrics)

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
                width = share.width(at: flexibleIndex)
                flexibleIndex += 1
            }
            slots.append(TabLayoutSlot(
                id: item.id,
                x: x,
                width: width,
                isPinned: item.isPinned,
                groupID: item.groupID,
                isGroupChip: item.isGroupChip,
                isCollapsed: item.isCollapsed,
                isFlexible: !item.isPinned && !item.isCollapsed && item.fixedWidth == nil
            ))
            x += width
            previousWasPinned = item.isPinned
        }
        return TabLayoutResult(
            slots: slots,
            contentWidth: x,
            standardWidth: share.standardWidth(count: flexible.count),
            availableWidth: available,
            share: share,
            flexibleCount: flexible.count,
            reservedWidth: reserved
        )
    }

    /// `result` laid out again at `availableWidth`, every other input as it was (SMOOTH-STRIP: a pane spring, a divider
    /// drag or a window resize changes only the strip's width, in each frame). The width reaches the slots only through
    /// how the flexible tabs share the row (``TabRowShare``): when that stays, so does every slot, and this is O(1);
    /// else the slots take the new share's widths in one walk. Equal to ``layout(items:availableWidth:style:metrics:closingModeWidth:fullWidthTab:)``
    /// with `result`'s items (`TabLayoutResizeTests`).
    public static func resized(_ result: TabLayoutResult, availableWidth: CGFloat, style: TabStripStyle, metrics: TabStripMetrics = .standard,
                               closingModeWidth: CGFloat? = nil) -> TabLayoutResult {
        let available = max(0, min(availableWidth, closingModeWidth ?? .infinity))
        if case .fullWidth = result.share {
            var passed = false
            var resized = result
            resized.slots = result.slots.map { slot in
                var slot = slot
                if slot.isCollapsed {
                    slot.x = passed ? available : 0
                } else {
                    passed = true
                    slot.width = available
                }
                return slot
            }
            (resized.contentWidth, resized.standardWidth, resized.availableWidth, resized.share) = (available, available, available, .fullWidth(available))
            return resized
        }
        let share = rowShare(count: result.flexibleCount, available: max(0, available - result.reservedWidth), style: style, metrics: metrics)
        var resized = result
        resized.availableWidth = available
        guard share != result.share else { return resized }
        resized.share = share
        resized.standardWidth = share.standardWidth(count: result.flexibleCount)
        var x: CGFloat = 0, flexibleIndex = 0, previousWasPinned = false
        for index in resized.slots.indices {
            if !resized.slots[index].isPinned, previousWasPinned { x += metrics.pinnedGroupGap }
            resized.slots[index].x = x
            if resized.slots[index].isFlexible {
                resized.slots[index].width = share.width(at: flexibleIndex)
                flexibleIndex += 1
            }
            x += resized.slots[index].width
            previousWasPinned = resized.slots[index].isPinned
        }
        resized.contentWidth = x
        return resized
    }

    /// `tab` across the whole strip; the rest collapse at its leading or trailing edge, so a
    /// mode change slides them in from where they sit.
    private static func fullWidthLayout(items: [TabLayoutItem], tab: TabID, available: CGFloat) -> TabLayoutResult {
        var passed = false
        let slots = items.map { item in
            guard item.id == tab else {
                return TabLayoutSlot(id: item.id, x: passed ? available : 0, width: 0, isPinned: false,
                                     groupID: item.groupID, isGroupChip: item.isGroupChip, isCollapsed: true)
            }
            passed = true
            // Not pinned in the slot: a pinned tab here is no fixed band, it is the whole strip.
            return TabLayoutSlot(id: item.id, x: 0, width: available, isPinned: false, groupID: item.groupID)
        }
        return TabLayoutResult(slots: slots, contentWidth: available, standardWidth: available, availableWidth: available, share: .fullWidth(available))
    }

    /// How `count` flexible tabs share `available` (the row less the pinned tabs and the content-sized items).
    static func rowShare(count: Int, available: CGFloat, style: TabStripStyle, metrics: TabStripMetrics) -> TabRowShare {
        guard count > 0 else { return .none }
        if style == .compact { return .each(metrics.compactTabWidth) }
        let ideal = available / CGFloat(count)
        if ideal >= metrics.maxTabWidth { return .each(metrics.maxTabWidth) }
        // Crowded: every tab shrinks evenly down to the inactive minimum, then the strip scrolls.
        // The selected tab gets no larger share (Chrome's active minimum): a selection never
        // moves or resizes a tab (Lawrence 2026-10-19). A narrow selected tab shows its x and
        // drops its title, then its icon (`TabChromeVisibility`).
        if count == 1 { return .alone(max(ideal.rounded(.down), metrics.minActiveTabWidth)) }
        if ideal >= metrics.minInactiveTabWidth {
            let (base, extra) = split(available, count: count)
            return .split(base: base, extra: extra)
        }
        return .each(metrics.minInactiveTabWidth)
    }

    /// `total` in `count` whole points: each part `base`, the first `extra` one point wider.
    static func split(_ total: CGFloat, count: Int) -> (base: CGFloat, extra: Int) {
        guard count > 0, total.isFinite, total > 0 else { return (0, 0) }
        let base = (total / CGFloat(count)).rounded(.down)
        return (base, max(0, min(count, Int((total - base * CGFloat(count)).rounded(.down)))))
    }

    /// Splits `total` into `count` whole-point widths. Leftover points go to
    /// the leading tabs, so the strip edge stays crisp.
    static func distribute(_ total: CGFloat, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let (base, extra) = split(total, count: count)
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
