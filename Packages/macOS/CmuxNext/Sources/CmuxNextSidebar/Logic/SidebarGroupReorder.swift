import CoreGraphics
import Foundation

/// Where a dragged group goes among the list's blocks (Lawrence 2026-10-19,
/// u2455: reorder by both edges of the dragged group, not its header's centre).
///
/// A block is one top-level thing of the list without the dragged group: a
/// group (its header, members and their tab rows), a loose workspace with its
/// tab rows, a listed item, a section header. The open gap stands at index
/// `current` (the blocks from `current` on are drawn pushed down by `shift`).
/// The card moves down one block when its bottom edge passes that block's
/// middle by `hysteresis(for:)`, and up one when its top edge passes the
/// middle of the block above by the same margin. Both edges count, so a tall
/// (expanded) group moves as soon as its bottom reaches a short neighbour's
/// middle, and a short (collapsed) group needs to reach a tall neighbour's
/// middle. After a move the card sits 2 × hysteresis inside the new place, so a
/// still pointer never flips between two places.
nonisolated struct SidebarGroupReorder: Sendable {
    /// The blocks, top to bottom, in the coordinates of the list drawn without the gap.
    var blocks: [ClosedRange<CGFloat>]
    /// How far the open gap pushes the blocks below it.
    var shift: CGFloat

    /// The share of a neighbour's height an edge must pass its middle by.
    static let hysteresisFraction: CGFloat = 0.2
    /// The most an edge must pass a neighbour's middle by, in points.
    static let maxHysteresis: CGFloat = 8

    /// The margin past a block's middle that moves the card, for a block `height` tall.
    static func hysteresis(for height: CGFloat) -> CGFloat {
        min(maxHysteresis, max(0, height) * hysteresisFraction)
    }

    /// The gap index for a card whose top and bottom edges are at `top` and
    /// `bottom` (displayed coordinates), the gap open at `current` now.
    func index(top: CGFloat, bottom: CGFloat, current: Int) -> Int {
        let start = min(max(0, current), blocks.count)
        var index = start
        // Down: the block after the gap is drawn pushed down by the gap.
        while index < blocks.count {
            let block = blocks[index]
            let height = block.upperBound - block.lowerBound
            guard bottom > (block.lowerBound + block.upperBound) / 2 + shift + Self.hysteresis(for: height) else { break }
            index += 1
        }
        if index != start { return index }
        // Up: the block before the gap is drawn where it is.
        while index > 0 {
            let block = blocks[index - 1]
            let height = block.upperBound - block.lowerBound
            guard top < (block.lowerBound + block.upperBound) / 2 - Self.hysteresis(for: height) else { break }
            index -= 1
        }
        return index
    }

    /// The gap index of an open gap starting at `gapY` (the blocks above it).
    func index(ofGapAt gapY: CGFloat) -> Int {
        blocks.count { $0.lowerBound < gapY - 0.5 }
    }

    /// A point (base coordinates) where a drop resolves to the gap at `index`:
    /// just above the end of the block before it (a drop after that block),
    /// or at the top of the first block for index 0.
    func probeY(for index: Int) -> CGFloat? {
        guard !blocks.isEmpty else { return nil }
        if index <= 0 { return blocks[0].lowerBound + min(0.5, (blocks[0].upperBound - blocks[0].lowerBound) / 2) }
        let before = blocks[min(index, blocks.count) - 1]
        return before.upperBound - min(0.5, (before.upperBound - before.lowerBound) / 2)
    }

    /// The top-level blocks of `layout`, top to bottom.
    static func blocks(of rows: [SidebarRow]) -> [ClosedRange<CGFloat>] {
        var blocks: [ClosedRange<CGFloat>] = []
        var open: (group: GroupID?, workspace: WorkspaceID?)? = nil
        for row in rows where row.height > 0 {
            let joins: Bool = switch row.key {
            case .workspace, .item: row.group != nil && row.group == open?.group
            case let .tab(owner, _): owner == open?.workspace || (row.group != nil && row.group == open?.group)
            default: false
            }
            if joins, let last = blocks.last {
                blocks[blocks.count - 1] = last.lowerBound...max(last.upperBound, row.maxY)
                continue
            }
            blocks.append(row.y...row.maxY)
            open = switch row.key {
            case let .group(id): (id, nil)
            case let .workspace(id): (nil, id)
            default: nil
            }
        }
        return blocks
    }
}
