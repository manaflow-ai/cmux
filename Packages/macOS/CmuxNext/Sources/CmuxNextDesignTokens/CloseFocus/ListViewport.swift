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
    /// itself, else the first partly visible item that survives
    /// (`ListViewportChange.anchor`, the one rule; this list reads its
    /// items one by one, a list of rows sorted by place reads the rows in view).
    public func anchor(at offset: CGFloat, next: ListViewport<ID>) -> Item? {
        change(to: next).anchor(at: offset)
    }

    /// The change from this list to `next`, each read through an index of its ids.
    private func change(to next: ListViewport<ID>) -> ListViewportChange<Indexed, Indexed> {
        ListViewportChange(from: Indexed(self), content: content, viewport: viewport,
                           to: Indexed(next), content: next.content, viewport: next.viewport)
    }

    /// The items by position and by id (the first item of an id), for the rules of `ListViewportChange`.
    private nonisolated struct Indexed: ListViewportRows {
        let items: [Item]
        let positions: [ID: Int]

        init(_ list: ListViewport<ID>) {
            items = list.items
            positions = Dictionary(list.items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        }

        var rowCount: Int { items.count }
        func viewportRow(at position: Int) -> Item { items[position] }
        func viewportPosition(of id: ID) -> Int? { positions[id] }
        // Any order of places: every item is read.
        func viewportPositions(endingAfter lower: CGFloat, startingBefore upper: CGFloat) -> [Int] {
            items.indices.filter { items[$0].end > lower && items[$0].start < upper }
        }
    }

    /// Step 1 of `settle`: the offset that keeps the anchor (`anchor`, the
    /// first visible row that stayed in place) at its on-screen position,
    /// so rows removed, added or moved before the visible ones do not move
    /// what the user sees, and a visible row that closes lets the rows
    /// below close the gap. Clamped.
    public func anchored(from old: ListViewport<ID>, offset: CGFloat) -> CGFloat {
        old.change(to: self).anchored(offset: offset)
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
        old.change(to: self).settle(offset: offset, focused: focused, newFocus: newFocus, padding: padding,
                                    userMoved: userMoved, extent: extent)
    }

    /// Whether item `id` moved by itself from `self` to `next`: among the
    /// items in both lists, it has a new neighbour on both sides (as
    /// `anchor` reads a move). A row closing or arriving beside it changes
    /// one neighbour only, and is no move.
    public func movedByItself(_ id: ID, in next: ListViewport<ID>) -> Bool {
        change(to: next).movedByItself(id)
    }
}

/// The rows of a list as the scroll rules read them (`ListViewportChange`): by position, by id, and the ones
/// partly inside a span. A list whose rows are sorted by place answers the last one by a search, so a rule
/// reads the rows in view and the rows beside a change, never every row of the list.
public nonisolated protocol ListViewportRows<ID> {
    associatedtype ID: Hashable & Sendable
    /// How many rows the list holds.
    var rowCount: Int { get }
    /// The row at `position`, in list order.
    func viewportRow(at position: Int) -> ListViewport<ID>.Item
    /// The position of the row `id`, or nil when the list does not hold it.
    func viewportPosition(of id: ID) -> Int?
    /// The positions, in list order, of the rows that end after `lower` and start before `upper`.
    func viewportPositions(endingAfter lower: CGFloat, startingBefore upper: CGFloat) -> [Int]
}

/// The scroll rules of `ListViewport` for a list that changes from `old` to `new` (contract V1 to V6 there),
/// read through `ListViewportRows`: the work is the rows in view plus the rows that left or came beside them,
/// at 60 rows as at 826 (WORKSPACE LIST 800: two lists of every row and two sets of every id were built for
/// each change). Chromium's tab strip takes a typed change (`TabStripModelChange`) and lays out from the
/// changed index; this rule reads from the rows in view for the same reason.
public nonisolated struct ListViewportChange<Old: ListViewportRows, New: ListViewportRows> where Old.ID == New.ID {
    public typealias ID = Old.ID
    public typealias Item = ListViewport<ID>.Item

    let old: Old
    let new: New
    /// The viewport and content of each list (no items: `clamp`, `reveal` and `isFullyVisible` read none).
    let oldFrame: ListViewport<ID>
    let newFrame: ListViewport<ID>

    public init(from old: Old, content oldContent: CGFloat, viewport oldViewport: CGFloat,
                to new: New, content newContent: CGFloat, viewport newViewport: CGFloat) {
        self.old = old
        self.new = new
        oldFrame = ListViewport(items: [], viewport: oldViewport, content: oldContent)
        newFrame = ListViewport(items: [], viewport: newViewport, content: newContent)
    }

    /// The item the user's eye rests on: the first partly visible item of `old` that `new` holds too and
    /// that did not move by itself, else the first partly visible one that `new` holds. An item moved by
    /// itself (a drop, a pin, a keyboard move) has a new surviving neighbour on both sides; an item beside
    /// the place a row left or arrived keeps one of them. A moved row is never the anchor while a row that
    /// stayed in place is visible, so the offset follows what the user sees, not the moved row.
    // perf-hot: 0.1ms workspace-list-change
    public func anchor(at offset: CGFloat) -> Item? {
        let epsilon = ListViewport<ID>.epsilon
        var firstSurviving: Item?
        for position in old.viewportPositions(endingAfter: offset + epsilon, startingBefore: offset + oldFrame.viewport - epsilon) {
            let item = old.viewportRow(at: position)
            guard let now = new.viewportPosition(of: item.id) else { continue }
            if firstSurviving == nil { firstSurviving = item }
            if keepsNeighbour(was: position, now: now) { return item }
        }
        return firstSurviving
    }

    /// Whether the row at `was` in `old` and `now` in `new` has, among the rows both lists hold, the same
    /// row before it or the same row after it (nil, an end of the list, counts as a row).
    private func keepsNeighbour(was: Int, now: Int) -> Bool {
        Self.neighbour(of: was, by: -1, in: old, among: new) == Self.neighbour(of: now, by: -1, in: new, among: old)
            || Self.neighbour(of: was, by: 1, in: old, among: new) == Self.neighbour(of: now, by: 1, in: new, among: old)
    }

    /// The first row before (`step` -1) or after (1) `position` in `rows` that `other` holds too: a walk over
    /// the rows that left or came beside it, one step when its neighbour survived. The only loop of the rule that
    /// can pass the rows in view: it reads as many rows as changed beside `position` (one for a close or a create,
    /// every row only when the two lists share none on that side).
    // perf-hot: 0.1ms workspace-list-change
    private static func neighbour<Rows: ListViewportRows, Other: ListViewportRows>(
        of position: Int, by step: Int, in rows: Rows, among other: Other
    ) -> ID? where Rows.ID == ID, Other.ID == ID {
        var index = position + step
        while index >= 0, index < rows.rowCount {
            let id = rows.viewportRow(at: index).id
            if other.viewportPosition(of: id) != nil { return id }
            index += step
        }
        return nil
    }

    /// The row `id` of `new`, or nil.
    private func item(_ id: ID) -> Item? { new.viewportPosition(of: id).map { new.viewportRow(at: $0) } }

    /// Step 1 of `settle`: the offset that keeps the anchor at its on-screen position. Clamped.
    public func anchored(offset: CGFloat) -> CGFloat {
        var next = offset
        if let anchor = anchor(at: offset), let moved = item(anchor.id) {
            next += moved.start - anchor.start
        }
        return newFrame.clamp(next)
    }

    /// The offset after the change (`ListViewport.settle`): anchor, reveal `newFocus` when it must show, clamp.
    /// `anchored`: the result of `anchored(offset:)` for this `offset`, when the caller has it already.
    public func settle(offset: CGFloat, anchored: CGFloat? = nil, focused: ID?, newFocus: ID?, padding: CGFloat, userMoved: Bool,
                       extent: Item? = nil) -> CGFloat {
        let next = anchored ?? self.anchored(offset: offset)
        guard let newFocus, let target = (newFocus != focused ? extent : nil) ?? item(newFocus) else { return next }
        let wasVisible = old.viewportPosition(of: newFocus).map { oldFrame.isFullyVisible(old.viewportRow(at: $0), at: offset, padding: 0) } ?? false
        guard newFocus != focused || userMoved || wasVisible || movedByItself(newFocus) else { return next }
        // Only an item that is not wholly in view scrolls; padding applies
        // to that scroll. A click on a row near the edge, or padding that
        // appears when rows are added past the end, moves nothing (the
        // second click of a double-click stays on the same row).
        if newFrame.isFullyVisible(target, at: next, padding: 0) { return next }
        return newFrame.reveal(target, from: next, padding: padding)
    }

    /// Whether item `id` moved by itself: among the items in both lists, it has a new neighbour on both
    /// sides (as `anchor` reads a move). A row closing or arriving beside it changes one neighbour only,
    /// and is no move.
    public func movedByItself(_ id: ID) -> Bool {
        guard let was = old.viewportPosition(of: id), let now = new.viewportPosition(of: id) else { return false }
        return !keepsNeighbour(was: was, now: now)
    }
}
