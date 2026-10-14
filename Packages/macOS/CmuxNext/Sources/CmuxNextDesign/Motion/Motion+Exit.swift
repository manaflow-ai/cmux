import Foundation

extension Motion {
    /// A pane a zoom leaves (Leo 2026-10-13: the opposite corner exits first and fastest): the
    /// farthest from the zoomed pane (`nearness` 0) fades on `exit`, its neighbours (1) up to a
    /// quarter slower.
    public static func exit(nearness: Double) -> SpringParameters {
        let base = spring(.exit)
        return SpringParameters(response: base.response * (1 + 0.25 * min(max(nearness, 0), 1)), dampingFraction: base.dampingFraction)
    }
}
