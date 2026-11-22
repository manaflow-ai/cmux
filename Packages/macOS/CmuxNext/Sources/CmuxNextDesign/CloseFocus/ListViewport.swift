public import CoreGraphics

/// One-axis scroll rules for a list viewport (the sidebar's workspace
/// list; plans/cmux-next/close-focus.md). Offsets are the content-space
/// coordinate of the viewport's leading edge. Pure.
///
/// Contract (ListViewportModelCheckTests, closefocus.tla):
/// - V1 the offset is clamped to `0...max(0, content - viewport)`,
/// - V2 after `settle`, the focused item is fully visible (with padding,
///   or covering the viewport when it is taller) whenever it must be
///   revealed: focus changed, or it was fully visible before,
/// - V3 no jump: a focused item that stays focused and was fully visible
///   keeps its on-screen position unless the clamp forces a move,
/// - V4 minimal: a reveal aligns the nearer edge, never more,
/// - V5 anchoring: when items before the visible ones leave or grow, what
///   the user sees stays put (the anchor keeps its on-screen position),
/// - V6 idempotent: settling the same geometry twice changes nothing (no
///   second scroll after the animation settles).
public nonisolated struct ListViewport<ID: Hashable & Sendable>: Hashable, Sendable {
    /// Content-space extents by id, in list order.
    public var items: [Item]
    public var viewport: CGFloat
    public var content: CGFloat

    public struct Item: Hashable, Sendable {
        public var id: ID
        public var start: CGFloat
        public var length: CGFloat
        public init(id: ID, start: CGFloat, length: CGFloat) {
            self.id = id
            self.start = start
            self.length = length
        }
        public var end: CGFloat { start + length }
    }

    public init(items: [Item], viewport: CGFloat, content: CGFloat) {
        self.items = items
        self.viewport = viewport
        self.content = content
    }

    /// Rounding slack for comparisons (offsets are fractional points).
    public static var epsilon: CGFloat { 0.01 }

    public func item(_ id: ID) -> Item? { items.first { $0.id == id } }

    public var maxOffset: CGFloat { max(0, content - viewport) }

    public func clamp(_ offset: CGFloat) -> CGFloat { min(max(offset, 0), maxOffset) }

    /// The item with `padding` on both sides (cut at the content's ends)
    /// lies inside the viewport, or the item is at least as long as the
    /// viewport and covers it.
    public func isFullyVisible(_ item: Item, at offset: CGFloat, padding: CGFloat) -> Bool {
        if item.length + padding * 2 >= viewport {
            return item.start <= offset + Self.epsilon && item.end >= offset + viewport - Self.epsilon
                || (item.start >= offset - Self.epsilon && item.end <= offset + viewport + Self.epsilon)
        }
        // Padding past either end of the content does not exist.
        let lead = max(0, item.start - padding), trail = min(content, item.end + padding)
        return lead >= offset - Self.epsilon && trail <= offset + viewport + Self.epsilon
    }

    /// The least scroll that shows `item` fully: unchanged when it shows,
    /// else the nearer edge aligned; an item taller than the viewport
    /// aligns its leading edge. Clamped.
    public func reveal(_ item: Item, from offset: CGFloat, padding: CGFloat) -> CGFloat {
        let current = clamp(offset)
        if isFullyVisible(item, at: current, padding: padding) { return current }
        if item.length + padding * 2 >= viewport { return clamp(item.start - max(0, (viewport - item.length) / 2)) }
        let toLeading = item.start - padding
        let toTrailing = item.end + padding - viewport
        return clamp(abs(toLeading - current) <= abs(toTrailing - current) ? toLeading : toTrailing)
    }

    /// The item the user's eye rests on: `preferred` when it was at least
    /// partly visible, else the first item that was partly visible.
    public func anchor(at offset: CGFloat, preferred: ID?, surviving: (ID) -> Bool) -> Item? {
        let visible = { (item: Item) in item.end > offset + Self.epsilon && item.start < offset + self.viewport - Self.epsilon }
        if let preferred, let item = item(preferred), visible(item), surviving(preferred) { return item }
        return items.first { visible($0) && surviving($0.id) }
    }

    /// Step 1 of `settle`: the offset that keeps the anchor (the focused
    /// item when it survives and was visible, else the first visible item
    /// that survives) at its on-screen position, so rows removed or added
    /// before the visible ones do not move what the user sees, and a
    /// visible row that closes lets the rows below close the gap. Clamped.
    public func anchored(from old: ListViewport<ID>, offset: CGFloat, focused: ID?) -> CGFloat {
        var next = offset
        if let anchor = old.anchor(at: offset, preferred: focused, surviving: { self.item($0) != nil }),
           let moved = item(anchor.id) {
            next += moved.start - anchor.start
        }
        return clamp(next)
    }

    /// The offset after the list changed from `old` (seen at `offset`) to
    /// `self`, with `focused` focused before and `newFocus` after:
    /// 1. anchor (`anchored`),
    /// 2. reveal `newFocus` when focus changed, or when it was fully visible
    ///    and the change pushed it (not just its padding) out of view,
    /// 3. clamp.
    public func settle(from old: ListViewport<ID>, offset: CGFloat, focused: ID?, newFocus: ID?, padding: CGFloat) -> CGFloat {
        let next = anchored(from: old, offset: offset, focused: focused)
        guard let newFocus, let target = item(newFocus) else { return next }
        let wasVisible = old.item(newFocus).map { old.isFullyVisible($0, at: offset, padding: padding) } ?? false
        guard newFocus != focused || wasVisible else { return next }
        // Only an item that is not wholly in view scrolls; padding applies
        // to that scroll. A click on a row near the edge, or padding that
        // appears when rows are added past the end, moves nothing (the
        // second click of a double-click stays on the same row).
        if isFullyVisible(target, at: next, padding: 0) { return next }
        return reveal(target, from: next, padding: padding)
    }
}
