import CoreGraphics

/// Which cards the grid shows when some tabs are stacked (`TabsKitStack`):
/// a folded stack is one card, its front tab, in the slot of the stack's
/// first tab; an open stack lists every tab of it there, one after another,
/// even when the source lists them apart. Pinned tabs never stack.
///
/// The front of a folded stack is the active tab when it is in the stack
/// (the tab you leave is the card you come back to), else the stack's own
/// front tab (the pane's shown tab), else its first.
struct TabStackPlan: Equatable, Sendable {
    struct Stack: Equatable, Sendable {
        var id: String
        var title: String
        /// Every tab of the stack, in the source's order.
        var members: [String]
        var isOpen: Bool
        /// The grid slot of the stack's first card (folded: its only card).
        var anchor: Int
        /// The tab a folded stack shows.
        var front: String
        /// Grid slots the stack takes: all its members open, one folded.
        var slots: Int { isOpen ? members.count : 1 }
    }

    /// Grid cards in order (tab ids).
    private(set) var visible: [String] = []
    private(set) var stacks: [Stack] = []
    /// A stacked tab's stack (index into `stacks`).
    private(set) var stackIndex: [String: Int] = [:]

    init() {}

    /// - Parameters:
    ///   - ids: the source's tabs, in order.
    ///   - stack: each tab's stack (nil: none).
    ///   - active: the active tab.
    ///   - open: the stacks shown open.
    ///   - pinned: pinned tabs (never stacked).
    init(ids: [String], stack: (String) -> TabsKitStack?, active: String?, open: Set<String>, pinned: Set<String> = []) {
        var order: [String] = []
        var info: [String: TabsKitStack] = [:]
        var members: [String: [String]] = [:]
        var keyOf: [String: String] = [:]
        for id in ids where !pinned.contains(id) {
            guard let s = stack(id) else { continue }
            if members[s.id] == nil {
                order.append(s.id)
                info[s.id] = s
            }
            members[s.id, default: []].append(id)
            keyOf[id] = s.id
        }
        var emitted: Set<String> = []
        for id in ids {
            guard let key = keyOf[id], let list = members[key], list.count > 1 else {
                visible.append(id)
                continue
            }
            guard !emitted.contains(key) else { continue }
            emitted.insert(key)
            let s = info[key]!
            let front = active.flatMap { list.contains($0) ? $0 : nil }
                ?? s.frontTabID.flatMap { list.contains($0) ? $0 : nil }
                ?? list[0]
            let isOpen = open.contains(key)
            let index = stacks.count
            stacks.append(Stack(id: key, title: s.title, members: list, isOpen: isOpen, anchor: visible.count, front: front))
            for m in list { stackIndex[m] = index }
            visible.append(contentsOf: isOpen ? list : [front])
        }
    }

    /// The stack `id` (a tab) is in, if it is in one of two or more tabs.
    func stack(of id: String) -> Stack? { stackIndex[id].map { stacks[$0] } }

    /// Tabs a folded stack hides (all but its front).
    func folded(_ stack: Stack) -> [String] {
        stack.isOpen ? [] : stack.members.filter { $0 != stack.front }
    }

    /// The stack whose first slot is grid slot `slot`.
    func stack(anchoredAt slot: Int) -> Stack? { stacks.first { $0.anchor == slot } }

    /// The source index for a card dragged to grid slot `slot` (the grid's
    /// order differs from the source's when a stack gathers tabs listed apart).
    func sourceIndex(forSlot slot: Int, ids: [String]) -> Int {
        guard slot >= 0, slot < visible.count, let i = ids.firstIndex(of: visible[slot]) else { return min(max(0, slot), max(0, ids.count - 1)) }
        return i
    }
}

/// The encasement's outline for a stack taking `count` slots from `first`:
/// the card rows it spans, as at most three rects (the first row from the
/// stack's first card, whole rows, the last row to its last card), each
/// covering the cards and their title rows, `pad` points out. Always three
/// rects (a shape that needs fewer repeats one), so the outline can be
/// interpolated slot by slot while a stack opens or folds.
struct StackOutlineRects: Equatable, Sendable {
    var a: CGRect
    var b: CGRect
    var c: CGRect

    var all: [CGRect] { [a, b, c] }

    static func make(layout: OverviewLayout, first: Int, count: Int, pad: CGFloat) -> StackOutlineRects {
        let count = max(1, count)
        let last = first + count - 1
        let title = OverviewLayout.titleRow + 2
        func cell(_ i: Int) -> CGRect {
            let r = layout.card(i)
            return CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height + title)
        }
        // Rows of the run: consecutive slots with the same card top.
        var rows: [CGRect] = []
        for i in first...last {
            let r = cell(i)
            if let prev = rows.last, abs(prev.minY - r.minY) < 0.5 {
                rows[rows.count - 1] = prev.union(r)
            } else {
                rows.append(r)
            }
        }
        let padded = rows.map { $0.insetBy(dx: -pad, dy: -pad) }
        switch padded.count {
        case 1: return StackOutlineRects(a: padded[0], b: padded[0], c: padded[0])
        case 2: return StackOutlineRects(a: padded[0], b: padded[1], c: padded[1])
        default:
            // First row, the whole rows between (one rect), last row.
            let middle = padded[1..<(padded.count - 1)].reduce(padded[1]) { $0.union($1) }
            return StackOutlineRects(a: padded[0], b: middle, c: padded[padded.count - 1])
        }
    }

    /// The pieces to union: the three rects, plus a bridge across the gap
    /// between two that overlap side to side (rows of one stack never touch
    /// otherwise: the row gap is wider than twice the padding).
    /// `overlap` is how far a bridge reaches into each row: the rows' corner
    /// radius, so the bridge covers their rounded corners on the shared side
    /// and an L's outer edge runs straight from row to row (a smaller reach
    /// left a notch where the corners curve in).
    func pieces(maxGap: CGFloat, overlap: CGFloat = 1) -> (rows: [CGRect], bridges: [CGRect]) {
        // Distinct rows only: a shape of one or two rows repeats a rect.
        var list: [CGRect] = []
        for r in all where !list.contains(where: { $0.equalTo(r) }) { list.append(r) }
        var bridges: [CGRect] = []
        for i in 0..<list.count {
            for j in (i + 1)..<list.count {
                let (top, bottom) = list[i].minY <= list[j].minY ? (list[i], list[j]) : (list[j], list[i])
                let gap = bottom.minY - top.maxY
                let x0 = max(top.minX, bottom.minX), x1 = min(top.maxX, bottom.maxX)
                guard gap > 0, gap <= maxGap, x1 - x0 > 1 else { continue }
                let reach = max(1, min(overlap, top.height / 2, bottom.height / 2))
                bridges.append(CGRect(x: x0, y: top.maxY - reach, width: x1 - x0, height: gap + 2 * reach))
            }
        }
        return (list, bridges)
    }
}
