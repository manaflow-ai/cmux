public import CoreGraphics

/// Decides when the titlebar controls accessory should recompute and re-apply
/// its layout. Both checks are pure comparisons within a `tolerance`, so a
/// sub-point resize or an equivalent snapshot produces no work.
public struct TitlebarControlsSizingPolicy {
    public init() {}

    /// Whether a view-size change from `previous` to `current` is large enough
    /// to warrant rescheduling a size update.
    ///
    /// Returns `false` for a non-positive `current` size, `true` the first time
    /// a positive size appears (from a non-positive `previous`), and otherwise
    /// `true` only when width or height moved by more than `tolerance`.
    public func shouldSchedule(
        previous: CGSize,
        current: CGSize,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        guard current.width > 0, current.height > 0 else { return false }
        guard previous.width > 0, previous.height > 0 else { return true }
        return abs(previous.width - current.width) > tolerance
            || abs(previous.height - current.height) > tolerance
    }

    /// Whether the `next` layout snapshot differs from `previous` by more than
    /// `tolerance` in any field, requiring the accessory to re-apply its frame.
    ///
    /// Returns `true` when there is no `previous` snapshot.
    public func shouldApplyLayout(
        previous: TitlebarControlsLayoutSnapshot?,
        next: TitlebarControlsLayoutSnapshot,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        guard let previous else { return true }
        return abs(previous.contentSize.width - next.contentSize.width) > tolerance
            || abs(previous.contentSize.height - next.contentSize.height) > tolerance
            || abs(previous.containerHeight - next.containerHeight) > tolerance
            || abs(previous.xOffset - next.xOffset) > tolerance
            || abs(previous.yOffset - next.yOffset) > tolerance
    }
}
