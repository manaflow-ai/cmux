import Foundation

/// Pure rules of the profile bar: visibility, stepping, and drag reorder.
public nonisolated enum ProfileBarLogic {
    /// The bar shows only while there is more than one profile.
    public static func isVisible(profileCount: Int) -> Bool { profileCount > 1 }

    /// The profile `delta` steps from `current` (swipe, next/previous),
    /// clamped at the ends like Arc (no wrap). Nil when nothing changes.
    public static func step(from current: ProfileKey?, by delta: Int, in order: [ProfileKey]) -> ProfileKey? {
        guard !order.isEmpty, delta != 0 else { return nil }
        let index = current.flatMap { order.firstIndex(of: $0) } ?? 0
        let target = min(max(index + delta, 0), order.count - 1)
        return target == index ? nil : order[target]
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

/// Recognizes one two-finger horizontal swipe over the sidebar (Arc): a
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
