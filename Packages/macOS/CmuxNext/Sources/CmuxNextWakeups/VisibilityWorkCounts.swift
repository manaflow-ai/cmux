/// The work the visibility tree ran for what shows, for `debug.layout_counters`. The app makes one
/// (`AppServices.visibilityWorkCounts`) and gives it to the roots it makes; a node counts into its root's
/// (``VisibilityNode/workCounts``), so a node moved under another tree counts there.
@MainActor public final class VisibilityWorkCounts {
    /// Appearance bodies ``VisibilityNode/deferAppearance(owner:_:)`` ran (recipe R-appear,
    /// `appearance_applies`): a theme flip adds one per owner on screen, then one per owner as its node shows.
    public internal(set) var appearanceApplies: UInt64 = 0

    public init() {}

    /// Starts every count again from zero (`debug.layout_counters` `reset`).
    public func reset() {
        appearanceApplies = 0
    }
}
