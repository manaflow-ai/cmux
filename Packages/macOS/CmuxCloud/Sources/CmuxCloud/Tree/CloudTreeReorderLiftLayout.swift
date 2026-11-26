import CoreGraphics

/// Geometry for a continuous machine drag in the Cloud tree.
///
/// The dragged machine (its row plus any open rows under it) is one block
/// that follows the pointer. Its peers part around it, and nothing in the
/// model moves until the drop. Everything is computed against row frames
/// frozen when the drag starts, so slot boundaries cannot move mid-drag and
/// the rows cannot oscillate.
public struct CloudTreeReorderLiftLayout: Equatable, Sendable {
    /// A run of rows that moves as one: a machine and its visible descendants.
    public struct Block: Equatable, Sendable {
        public let rows: Range<Int>
        /// A machine the source can trade places with. Other blocks inside the
        /// span (a pending create, a machine in another pin tier) keep their slot.
        public let isPeer: Bool

        public init(rows: Range<Int>, isPeer: Bool) {
            self.rows = rows
            self.isPeer = isPeer
        }
    }

    /// Where everything stands for one pointer position.
    public struct Placement: Equatable, Sendable {
        /// The source's index among the other peers once dropped, 0...peerCount.
        public let slot: Int
        /// The source block's translation: the pointer's, held inside the span.
        public let sourceOffset: CGFloat
        /// The translation that would put the source block in `slot`.
        public let sourceSlotOffset: CGFloat
        /// The translation of every other row in the span, zero for rows that stay.
        public let rowOffsets: [Int: CGFloat]
    }

    /// How far past the span the block can be pulled before it stops, in points.
    public static let overscrollLimit: CGFloat = 24

    private let frames: [CGRect]
    /// The blocks from the first peer or source to the last, in display order.
    private let span: [Block]
    /// The source's index in `span`.
    private let source: Int

    /// The number of peers the source can be placed among.
    public var peerCount: Int { span.filter(\.isPeer).count - (span[source].isPeer ? 1 : 0) }

    /// - Parameters:
    ///   - frames: Every row's frame, indexed by row, in a flipped (top-down) space.
    ///   - blocks: The source's sibling blocks in display order.
    ///   - sourceIndex: The source's index in `blocks`.
    public init?(frames: [CGRect], blocks: [Block], sourceIndex: Int) {
        guard blocks.indices.contains(sourceIndex),
              blocks.allSatisfy({ !$0.rows.isEmpty && $0.rows.lowerBound >= 0 && $0.rows.upperBound <= frames.count })
        else { return nil }
        let movable = blocks.indices.filter { blocks[$0].isPeer || $0 == sourceIndex }
        guard let first = movable.first, let last = movable.last else { return nil }
        self.frames = frames
        span = Array(blocks[first...last])
        source = sourceIndex - first
    }

    public func placement(dragOffset: CGFloat) -> Placement {
        let sourceBlock = span[source]
        let sourceTop = top(sourceBlock)
        let sourceHeight = height(sourceBlock)
        let minOffset = top(span[0]) - sourceTop
        let maxOffset = bottom(span[span.count - 1]) - bottom(sourceBlock)
        let held = min(max(dragOffset, minOffset), maxOffset)
        let dragTop = sourceTop + held
        let dragBottom = dragTop + sourceHeight

        // A peer gives way once the block covers half of the smaller of the
        // two, so a tall open machine doesn't have to be crossed halfway
        // before a one-line neighbour moves, and vice versa.
        var slot = 0
        for index in span.indices where span[index].isPeer && index != source {
            let peer = span[index]
            let reach = min(height(peer), sourceHeight) / 2
            if index < source {
                if dragTop >= bottom(peer) - reach { slot += 1 }
            } else if dragBottom > top(peer) + reach {
                slot += 1
            }
        }

        // Re-lay the span in drop order. Fixed blocks keep their positions;
        // the peers and the source fill the others.
        var order = span.indices.filter { span[$0].isPeer && $0 != source }
        order.insert(source, at: slot)
        var nextMovable = order.makeIterator()
        var offsets: [Int: CGFloat] = [:]
        var y = top(span[0])
        for position in span.indices {
            let index = span[position].isPeer || position == source ? nextMovable.next() ?? position : position
            offsets[index] = y - top(span[index])
            y += height(span[index])
            if position + 1 < span.count {
                y += top(span[position + 1]) - bottom(span[position])
            }
        }

        var rowOffsets: [Int: CGFloat] = [:]
        for index in span.indices where index != source {
            for row in span[index].rows { rowOffsets[row] = offsets[index] ?? 0 }
        }
        return Placement(
            slot: slot,
            sourceOffset: held + Self.overscroll(dragOffset - held),
            sourceSlotOffset: offsets[source] ?? 0,
            rowOffsets: rowOffsets
        )
    }

    /// Resistance past the span's ends: the block follows a little, then stops.
    static func overscroll(_ excess: CGFloat) -> CGFloat {
        guard excess != 0 else { return 0 }
        let limit = overscrollLimit
        let pulled = (1 - 1 / (abs(excess) * 0.55 / limit + 1)) * limit
        return excess < 0 ? -pulled : pulled
    }

    private func top(_ block: Block) -> CGFloat { frames[block.rows.lowerBound].minY }
    private func bottom(_ block: Block) -> CGFloat { frames[block.rows.upperBound - 1].maxY }
    private func height(_ block: Block) -> CGFloat { bottom(block) - top(block) }
}
