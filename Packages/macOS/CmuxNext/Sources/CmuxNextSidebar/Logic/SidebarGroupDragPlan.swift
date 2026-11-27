import CoreGraphics
import Foundation

/// A dragged group's whole drag as pure geometry (plans/cmux-next/sidebar-owner.md, "Group drag: design for the
/// rewrite"; Lawrence 2026-10-23: "rethink from first principles").
///
/// At lift the list without the dragged group is laid out once: the *base*. Its top-level blocks (a group with
/// its members, subgroups and their rows; a loose workspace; a listed item; a section header)
/// are y ranges in that base. Nothing during the drag reads a drawn or animating frame.
///
/// - The card is the group cut to its header and three rows (``cardHeight(rows:top:full:maxRows:)``); the gap it
///   opens is that height plus the spacing to the next block (``gap``).
/// - The slot is a step function of the card's centre alone (``slot(cardCentre:)``): no current gap, no
///   direction, no hysteresis, so the same pointer always shows the same rows.
/// - The drawn list is one function of (base, slot): a row at or below the slot's top moves down by the gap,
///   every other row stays, and the dragged rows (hidden under the card) stand in the gap
///   (``layout(_:slot:)``). The landing frame is the slot's top (``top(of:)``) at the card's height, from the
///   same function, so a drop does not jump.
nonisolated struct SidebarGroupDragPlan: Sendable, Equatable {
    /// One top-level block of the base: its y range, its first row and the node index right after it.
    struct Block: Equatable, Sendable {
        /// The block's rows, top to bottom, in base coordinates.
        var range: ClosedRange<CGFloat>
        /// The block's first row: a top-level group's header, a loose workspace or item, a section header.
        var head: SidebarRow
        /// The node index right after the block: past a group's subgroups, which are nodes of the section too.
        var nextIndex: Int
    }

    /// The base's blocks, top to bottom.
    let blocks: [Block]
    /// The lifted card's height (capped).
    let card: CGFloat
    /// The spacing the list keeps between the card and the block after it.
    let trail: CGFloat
    /// The spacing the list keeps between the block before the card and the card (the slot past the last block).
    let lead: CGFloat
    /// Where the group's top was at lift (base coordinates).
    let groupTop: CGFloat
    /// The slot the group came from: a drop there moves nothing.
    let origin: Int
    /// Which slots (0 through `blocks.count`) take the drop; the origin always does.
    let allowed: [Bool]
    /// The dragged rows (hidden under the card), y from the card's top.
    let carried: [SidebarRow]

    /// How far the open gap pushes the blocks at and below the slot.
    var gap: CGFloat { card + trail }

    /// The rows past the cap fade under a bottom edge this tall (at most a third of the card).
    static let fade: CGFloat = 16

    /// A plan over `blocks` (``blocks(of:)`` of the base) for a card `card` tall whose top was at `groupTop`.
    ///
    /// - Parameters:
    ///   - lead: The spacing above the card in the slot past the last block.
    ///   - trail: The spacing between the card and the block below it.
    ///   - allowed: Per slot (0 through `blocks.count`), whether a drop there is accepted; nil: every slot is.
    ///   - carried: The dragged rows, y from the card's top (they stand in the gap, inside the card).
    init(blocks: [Block], groupTop: CGFloat, card: CGFloat, lead: CGFloat, trail: CGFloat, allowed: [Bool]? = nil,
         carried: [SidebarRow] = []) {
        self.blocks = blocks
        self.carried = carried
        self.groupTop = groupTop
        self.card = card
        self.lead = lead
        self.trail = trail
        let origin = Self.rawSlot(top: groupTop, in: blocks)
        self.origin = origin
        var accepts = allowed ?? Array(repeating: true, count: blocks.count + 1)
        if accepts.count != blocks.count + 1 { accepts = Array(repeating: false, count: blocks.count + 1) }
        accepts[origin] = true
        self.allowed = accepts
    }

    /// The slot a card whose centre is at `centre` (list coordinates) takes.
    ///
    /// The card's centre in base space is its top (the gap the card stands in collapses to the slot's top): the
    /// slot is the number of blocks whose base midpoint is above it. Moving down, the card goes past a block once
    /// its bottom reaches that block's drawn middle (less the spacing); moving up, once its top reaches the drawn
    /// middle of the block above. A slot the drop cannot take gives the nearest one that can (the upper on a tie).
    func slot(cardCentre centre: CGFloat) -> Int {
        let raw = Self.rawSlot(top: centre - card / 2, in: blocks)
        if allowed[raw] { return raw }
        for distance in 1...max(1, blocks.count) {
            if raw - distance >= 0, allowed[raw - distance] { return raw - distance }
            if raw + distance <= blocks.count, allowed[raw + distance] { return raw + distance }
        }
        return origin
    }

    /// The number of blocks whose midpoint is above `y` (binary search: the midpoints rise top to bottom).
    private static func rawSlot(top y: CGFloat, in blocks: [Block]) -> Int {
        var low = 0, high = blocks.count
        while low < high {
            let mid = (low + high) / 2
            let block = blocks[mid].range
            if (block.lowerBound + block.upperBound) / 2 < y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The top of the card standing in `slot` (base and drawn coordinates: nothing above it moves).
    func top(of slot: Int) -> CGFloat {
        if blocks.indices.contains(slot) { return blocks[slot].range.lowerBound }
        return blocks.last.map { $0.range.upperBound + lead } ?? groupTop
    }

    /// The list as drawn with the card in `slot`: `base` with every row at or below the slot's top moved down by
    /// the gap, and the dragged rows in the gap (a row past the cut stands at the card's bottom, under the card).
    /// The gap is marked (`gapY`, `gapShift`) for the drop probe; nothing draws in it but the card.
    func layout(_ base: SidebarLayout, slot: Int) -> SidebarLayout {
        var layout = base
        let slotTop = top(of: slot)
        let inGap = carried.map { row in
            var row = row
            row.y = slotTop + min(row.y, max(0, card - row.height))
            return row
        }
        let first = layout.rows.firstIndex(where: { $0.y >= slotTop - 0.5 }) ?? layout.rows.count
        layout.replaceRows(first..<first, with: inGap, shiftingFollowingBy: gap)
        if let y = layout.pinnedChatsY, y >= slotTop - 0.5 { layout.pinnedChatsY = y + gap }
        if let y = layout.earlierChatsY, y >= slotTop - 0.5 { layout.earlierChatsY = y + gap }
        layout.gapY = slotTop
        layout.gapShift = gap
        layout.gapHeight = 0
        return layout
    }

    /// The lifted card's height: the whole block when it has at most `maxRows` rows under its header, else cut at
    /// the bottom of the `maxRows`-th row under the header.
    ///
    /// - Parameters:
    ///   - rows: The lifted rows' y ranges, top to bottom (the header first); empty rows do not count.
    ///   - top: The card's top.
    ///   - full: The card's uncut height.
    static func cardHeight(rows: [ClosedRange<CGFloat>], top: CGFloat, full: CGFloat, maxRows: Int = 3) -> CGFloat {
        let shown = rows.filter { $0.upperBound > $0.lowerBound }
        guard shown.count > maxRows + 1 else { return full }
        return min(full, shown[maxRows].upperBound - top)
    }

    /// The top-level blocks of `rows` (a laid-out list), top to bottom.
    ///
    /// A block opens at a top-level row and takes the rows that belong to it. A group's block holds its header,
    /// its members, its "Done" and "Show more" rows and every subgroup under it (rows deeper than the top level),
    /// so a parent and its subgroups are one block. A loose workspace's block is its row.
    static func blocks(of rows: [SidebarRow]) -> [Block] {
        var blocks: [Block] = []
        var openGroup: GroupID?
        for case var row in rows where row.height > 0 {
            // A group's one row starts its group's block, as its header did (`SidebarLayout+SoleMember`).
            if let header = row.standingHeader { row = header }
            let inOpenGroup = openGroup != nil && (row.group == openGroup || row.depth > 0)
            let joins: Bool = switch row.key {
            case .workspace, .item, .group, .doneFold, .showMore: inOpenGroup
            default: false
            }
            if joins, let last = blocks.last {
                blocks[blocks.count - 1].range = last.range.lowerBound...max(last.range.upperBound, row.maxY)
                if case .group = row.key { blocks[blocks.count - 1].nextIndex = max(last.nextIndex, row.siblingIndex + 1) }
                continue
            }
            blocks.append(Block(range: row.y...row.maxY, head: row, nextIndex: row.siblingIndex + 1))
            openGroup = if case let .group(id) = row.key { id } else { nil }
        }
        return blocks
    }
}
