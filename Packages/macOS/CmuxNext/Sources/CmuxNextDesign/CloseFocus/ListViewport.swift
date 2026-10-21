public import CoreGraphics

/// One-axis scroll rules for a list viewport (the sidebar's workspace
/// list; plans/cmux-next/close-focus.md). Offsets are the content-space
/// coordinate of the viewport's leading edge. Pure.
///
/// Contract (ListViewportModelCheckTests, closefocus.tla):
/// - V1 the offset is clamped to `0...max(0, content - viewport)`,
/// - V2 after `settle`, the focused item is fully visible (with padding,
///   or covering the viewport when it is taller) whenever it must be
///   revealed: focus changed, it moved by itself, or it was fully visible before,
/// - V3 no jump: a visible item that stays in place (only rows before it
///   change) keeps its on-screen position unless the clamp forces a move,
/// - V4 minimal: a reveal aligns the nearer edge, never more,
/// - V5 anchoring: when items before the visible ones leave, arrive, move
///   or grow, what the user sees stays put (the anchor, the first visible
///   row that did not move by itself, keeps its on-screen position),
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

    /// The item the user's eye rests on when the list changes to `next`:
    /// the first partly visible item that survives and did not move by
    /// itself, else the first partly visible item that survives. An item
    /// moved by itself (a drop, a pin, a keyboard move) has a new surviving
    /// neighbour on both sides; an item beside the place a row left or
    /// arrived keeps one of them. A moved row is never the anchor while a
    /// row that stayed in place is visible, so the offset follows what the
    /// user sees, not the moved row.
    public func anchor(at offset: CGFloat, next: ListViewport<ID>) -> Item? {
        let visible = { (item: Item) in item.end > offset + Self.epsilon && item.start < offset + self.viewport - Self.epsilon }
        let newIDs = Set(next.items.map(\.id))
        guard items.contains(where: { visible($0) && newIDs.contains($0.id) }) else { return nil }
        let oldIDs = Set(items.map(\.id))
        let before = Self.neighbours(items.map(\.id).filter { newIDs.contains($0) })
        let after = Self.neighbours(next.items.map(\.id).filter { oldIDs.contains($0) })
        var firstSurviving: Item?
        for item in items where visible(item) && newIDs.contains(item.id) {
            if firstSurviving == nil { firstSurviving = item }
            guard let old = before[item.id], let new = after[item.id] else { continue }
            if old.previous == new.previous || old.next == new.next { return item }
        }
        return firstSurviving
    }

    /// Each id's previous and next id in `order` (nil at the ends).
    private static func neighbours(_ order: [ID]) -> [ID: (previous: ID?, next: ID?)] {
        var result: [ID: (previous: ID?, next: ID?)] = [:]
        result.reserveCapacity(order.count)
        for (index, id) in order.enumerated() {
            result[id] = (index > 0 ? order[index - 1] : nil, index + 1 < order.count ? order[index + 1] : nil)
        }
        return result
    }

    /// Step 1 of `settle`: the offset that keeps the anchor (`anchor`, the
    /// first visible row that stayed in place) at its on-screen position,
    /// so rows removed, added or moved before the visible ones do not move
    /// what the user sees, and a visible row that closes lets the rows
    /// below close the gap. Clamped.
    public func anchored(from old: ListViewport<ID>, offset: CGFloat) -> CGFloat {
        var next = offset
        if let anchor = old.anchor(at: offset, next: self), let moved = item(anchor.id) {
            next += moved.start - anchor.start
        }
        return clamp(next)
    }

    /// The offset after the list changed from `old` (seen at `offset`) to
    /// `self`, with `focused` focused before and `newFocus` after:
    /// 1. anchor (`anchored`),
    /// 2. reveal `newFocus` (sidebar-focused-visible: the focused row is
    ///    always in view) when focus changed, when it moved by itself (a
    ///    drop, Move to Top, a sort, a regroup, a move from the CLI or another
    ///    client: `movedByItself`), when it was in view and the change pushed
    ///    it out, or when `userMoved` (a keyboard move, the Move Up/Down
    ///    action). A user who scrolled the focused row out of view keeps that
    ///    view through changes that do not move it,
    /// 3. clamp.
    ///
    /// `extent` is what a focus change reveals for `newFocus` when that is
    /// more than its own item (its header and the list's top above it, an
    /// item drawn inside a larger row). Other reveals (a move, a push out of
    /// view) show the item alone, so a list the user scrolled keeps a header
    /// out of view while its row shows.
    public func settle(from old: ListViewport<ID>, offset: CGFloat, focused: ID?, newFocus: ID?, padding: CGFloat,
                       userMoved: Bool, extent: Item? = nil) -> CGFloat {
        let next = anchored(from: old, offset: offset)
        guard let newFocus, let target = (newFocus != focused ? extent : nil) ?? item(newFocus) else { return next }
        let wasVisible = old.item(newFocus).map { old.isFullyVisible($0, at: offset, padding: 0) } ?? false
        guard newFocus != focused || userMoved || wasVisible || old.movedByItself(newFocus, in: self) else { return next }
        // Only an item that is not wholly in view scrolls; padding applies
        // to that scroll. A click on a row near the edge, or padding that
        // appears when rows are added past the end, moves nothing (the
        // second click of a double-click stays on the same row).
        if isFullyVisible(target, at: next, padding: 0) { return next }
        return reveal(target, from: next, padding: padding)
    }

    /// Whether item `id` moved by itself from `self` to `next`: among the
    /// items in both lists, it has a new neighbour on both sides (as
    /// `anchor` reads a move). A row closing or arriving beside it changes
    /// one neighbour only, and is no move.
    public func movedByItself(_ id: ID, in next: ListViewport<ID>) -> Bool {
        let oldIDs = Set(items.map(\.id)), newIDs = Set(next.items.map(\.id))
        guard oldIDs.contains(id), newIDs.contains(id) else { return false }
        guard let before = Self.neighbours(items.map(\.id).filter { newIDs.contains($0) })[id],
              let after = Self.neighbours(next.items.map(\.id).filter { oldIDs.contains($0) })[id] else { return false }
        return before.previous != after.previous && before.next != after.next
    }
}
