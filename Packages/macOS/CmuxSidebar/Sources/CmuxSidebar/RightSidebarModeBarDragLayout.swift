public import CoreGraphics

/// Geometry for dragging one of the right sidebar's mode tabs along the bar.
///
/// The dragged tab follows the pointer and the others part around it. Every
/// decision is made against the tab frames frozen when the drag starts, so
/// slot boundaries cannot move mid-drag and the tabs cannot oscillate.
/// Nothing is saved until the drop.
public struct RightSidebarModeBarDragLayout: Equatable {
    /// How far past the bar's ends the tab can be pulled before it stops, in points.
    public static let overscrollLimit: CGFloat = 16

    /// Tab frames in display order, frozen at drag start.
    public let frames: [CGRect]
    /// The dragged tab's index in `frames`.
    public let source: Int

    public init?(frames: [CGRect], source: Int) {
        guard frames.indices.contains(source), frames.allSatisfy({ $0.width > 0 }) else { return nil }
        self.frames = frames
        self.source = source
    }

    /// The dragged tab's translation: the pointer's, held inside the bar,
    /// with a little resistance past either end.
    public func draggedOffset(translation: CGFloat) -> CGFloat {
        let held = heldOffset(translation)
        return held + Self.overscroll(translation - held)
    }

    /// The index the dragged tab takes once dropped. A neighbour gives way
    /// once the tab covers half of the narrower of the two, so a wide tab
    /// does not have to be crossed halfway before a narrow one moves.
    public func slot(translation: CGFloat) -> Int {
        let dragged = frames[source]
        let minX = dragged.minX + heldOffset(translation)
        let maxX = minX + dragged.width
        var slot = 0
        for index in frames.indices where index != source {
            let reach = min(frames[index].width, dragged.width) / 2
            if index < source {
                if minX >= frames[index].maxX - reach { slot += 1 }
            } else if maxX > frames[index].minX + reach {
                slot += 1
            }
        }
        return slot
    }

    /// Every tab's translation with the dragged tab dropped at `slot`. The
    /// dragged tab's entry is where it would land; the gaps between
    /// positions keep their widths.
    public func offsets(slot: Int) -> [CGFloat] {
        var offsets = Array(repeating: CGFloat(0), count: frames.count)
        var x = frames[0].minX
        for (position, index) in reordered(Array(frames.indices), slot: slot).enumerated() {
            offsets[index] = x - frames[index].minX
            x += frames[index].width
            if position + 1 < frames.count {
                x += frames[position + 1].minX - frames[position].maxX
            }
        }
        return offsets
    }

    /// `items` (one per tab, in display order) with the dragged one at `slot`.
    public func reordered<Item>(_ items: [Item], slot: Int) -> [Item] {
        guard items.count == frames.count else { return items }
        var result = items
        let item = result.remove(at: source)
        result.insert(item, at: min(max(slot, 0), result.count))
        return result
    }

    /// True once the pointer is outside the mode bar, toward a pane. The main
    /// workspace is to the left of the right sidebar, so crossing x = 0 must
    /// hand off just like leaving vertically does.
    public static func leavesBar(pointer: CGPoint, tabFrame: CGRect, barHeight: CGFloat) -> Bool {
        let margin = max(barHeight, tabFrame.height) / 2
        return pointer.x < 0
            || pointer.y < tabFrame.minY - margin
            || pointer.y > tabFrame.maxY + margin
    }

    private func heldOffset(_ translation: CGFloat) -> CGFloat {
        let dragged = frames[source]
        let minOffset = frames[0].minX - dragged.minX
        let maxOffset = frames[frames.count - 1].maxX - dragged.maxX
        return min(max(translation, minOffset), maxOffset)
    }

    /// Resistance past the bar's ends: the tab follows a little, then stops.
    static func overscroll(_ excess: CGFloat) -> CGFloat {
        guard excess != 0 else { return 0 }
        let limit = overscrollLimit
        let pulled = (1 - 1 / (abs(excess) * 0.55 / limit + 1)) * limit
        return excess < 0 ? -pulled : pulled
    }
}
