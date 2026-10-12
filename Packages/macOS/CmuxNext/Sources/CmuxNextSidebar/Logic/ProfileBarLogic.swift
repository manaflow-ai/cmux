public import CoreGraphics
import Foundation

/// Pure rules of the profile bar: visibility, stepping, and drag reorder.
public nonisolated enum ProfileBarLogic {
    /// The bar shows only while there is more than one profile.
    public static func isVisible(profileCount: Int) -> Bool { profileCount > 1 }

    /// The profile `delta` steps from `current` (swipe, next/previous),
    /// clamped at the ends (no wrap). Nil when nothing changes.
    public static func step(from current: ProfileKey?, by delta: Int, in order: [ProfileKey]) -> ProfileKey? {
        guard !order.isEmpty, delta != 0 else { return nil }
        let index = current.flatMap { order.firstIndex(of: $0) } ?? 0
        let target = min(max(index + delta, 0), order.count - 1)
        return target == index ? nil : order[target]
    }

    /// The strip of spaces in a bar `width` wide (cx-5k3r, Lawrence
    /// 2026-10-08: "center spaces in bottom; spaces should show better").
    /// The dots are centered on `center` (the sidebar's middle, in bar
    /// coordinates) and clamped into the bar, never starting before
    /// `minLeading` and never reaching the trailing `plus` slot, so the "+"
    /// (shown on hover at the bar's trailing edge) never moves them. When the
    /// spaces do not fit at `slot` each, every slot narrows to fit down to
    /// `fullMinimum`; below that the strip turns compact: the active space
    /// keeps a full slot and the others share the rest as small dots, at least
    /// `compactMinimum` each (a strip that still does not fit is clipped).
    public static func strip(count: Int, active: Int?, width: Double, center: Double, minLeading: Double = 0,
                             slot: Double, plus: Double, fullMinimum: Double, compactMinimum: Double) -> SpaceStrip {
        let plusX = max(minLeading, width - plus)
        guard count > 0 else { return SpaceStrip(slots: [], plus: (plusX, plus), compact: false) }
        let room = max(0, plusX - minLeading)
        var widths = Array(repeating: slot, count: count)
        var compact = false
        if Double(count) * slot > room {
            let even = room / Double(count)
            if even >= fullMinimum {
                widths = Array(repeating: even, count: count)
            } else if let active, widths.indices.contains(active), count > 1 {
                compact = true
                let rest = max(compactMinimum, (room - slot) / Double(count - 1))
                widths = widths.indices.map { $0 == active ? slot : rest }
            } else {
                widths = Array(repeating: max(compactMinimum, even), count: count)
                compact = even < fullMinimum
            }
        }
        let total = widths.reduce(0, +)
        let start = max(minLeading, min(center - total / 2, plusX - total))
        var x = start
        let slots = widths.map { width -> (x: Double, width: Double) in
            defer { x += width }
            return (x, width)
        }
        return SpaceStrip(slots: slots, plus: (plusX, plus), compact: compact)
    }

    /// The hover background of a space (F2): its slot inset by `inset` on
    /// every side, at most as tall as it is wide, centered in the slot.
    public static func chipRect(slot: CGRect, inset: CGFloat) -> CGRect {
        let width = max(0, slot.width - inset * 2)
        let height = min(width, max(0, slot.height - inset * 2))
        return CGRect(x: slot.midX - width / 2, y: slot.midY - height / 2, width: width, height: height)
    }

    /// Insertion index (the `move-workspace` rule: an index into the list
    /// before removal) for a dot dragged to horizontal offset `x`, given the
    /// dots' center x positions in order.
    public static func insertionIndex(forX x: Double, centers: [Double]) -> Int {
        centers.firstIndex { x < $0 } ?? centers.count
    }

    /// The final position a dragged dot at `from` lands in after insertion
    /// at `index` (for local optimistic order). Nil when it does not move.
    public static func finalIndex(from: Int, insertion index: Int, count: Int) -> Int? {
        let target = index > from ? index - 1 : index
        let clamped = min(max(target, 0), max(count - 1, 0))
        return clamped == from ? nil : clamped
    }
}

/// Where each space and the "+" sit in the bar (`ProfileBarLogic.strip`).
public nonisolated struct SpaceStrip: Sendable {
    /// One slot per space, in order: its leading x and width.
    public var slots: [(x: Double, width: Double)]
    /// The "+" slot at the bar's trailing edge.
    public var plus: (x: Double, width: Double)
    /// The spaces are too many for full slots: the inactive ones draw as
    /// small dots and the active one keeps its full mark.
    public var compact: Bool

    /// The strip's horizontal middle (the dots only, not the "+").
    public var midX: Double? {
        guard let first = slots.first, let last = slots.last else { return nil }
        return (first.x + last.x + last.width) / 2
    }
}

/// Recognizes one two-finger horizontal swipe over the sidebar: a
/// trackpad gesture whose horizontal travel passes `threshold` and clearly
/// dominates vertical travel switches the profile once per gesture.
public nonisolated struct ProfileSwipeTracker: Sendable {
    public enum Phase: Sendable { case began, changed, ended, momentum }

    public var threshold: Double
    private var dx = 0.0
    private var dy = 0.0
    private var fired = false
    private var active = false

    public init(threshold: Double = 60) { self.threshold = threshold }

    /// Whether the gesture so far is horizontal (the sidebar should not
    /// scroll vertically for it).
    public var isHorizontal: Bool { active && abs(dx) > abs(dy) * 2 && abs(dx) > 4 }

    /// Feeds one scroll event. Returns -1 (previous) or +1 (next) once per
    /// gesture when it qualifies. Positive `deltaX` is a swipe to the right
    /// (content moves right), which goes to the previous profile.
    public mutating func feed(deltaX: Double, deltaY: Double, phase: Phase) -> Int? {
        switch phase {
        case .began:
            dx = deltaX
            dy = deltaY
            fired = false
            active = true
        case .changed:
            guard active else { return nil }
            dx += deltaX
            dy += deltaY
        case .ended, .momentum:
            active = false
            return nil
        }
        guard !fired, abs(dx) >= threshold, abs(dx) > abs(dy) * 2 else { return nil }
        fired = true
        return dx > 0 ? -1 : 1
    }
}
