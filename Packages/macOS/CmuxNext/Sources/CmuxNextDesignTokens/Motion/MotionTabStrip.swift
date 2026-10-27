import CCmuxMotionFFI
public import Foundation

/// The tab strip geometry of the Chrome motion (design-tokens.json
/// `motion.tabStrip`, through the app FFI).
public nonisolated struct MotionTabStrip: Equatable, Sendable {
    public var maxWidth: CGFloat
    /// A new tab starts this wide at the previous tab's right edge minus this.
    public var openStartWidth: CGFloat
    /// A closing tab ends this wide, its left edge pinned to the previous tab's right edge minus this.
    public var closeEndWidth: CGFloat
    public var minActiveWidth: CGFloat
    public var minInactiveWidth: CGFloat
    public var pinnedWidth: CGFloat
    /// Pointer travel since the last reorder that reorders again, at `maxWidth`.
    public var reorderThreshold: CGFloat
    /// Mouse closing mode ends this far below the strip, or this far past its trailing edge ...
    public var closingModeBelowPad: CGFloat
    public var closingModeTrailingPad: CGFloat
    /// ... plus this many seconds.
    public var closingModeExitDelay: TimeInterval

    /// The spec's geometry for `comfortable` (else compact) density.
    public init(comfortable: Bool) {
        var g = CmuxMotionTabStripGeometry()
        _ = cmux_motion_tab_strip_geometry(comfortable ? 1 : 0, &g)
        maxWidth = g.max_width
        openStartWidth = g.open_start_width
        closeEndWidth = g.close_end_width
        minActiveWidth = g.min_active_width
        minInactiveWidth = g.min_inactive_width
        pinnedWidth = g.pinned_width
        reorderThreshold = g.reorder_threshold
        closingModeBelowPad = g.closing_mode_below_pad
        closingModeTrailingPad = g.closing_mode_trailing_pad
        closingModeExitDelay = g.closing_mode_exit_delay
    }

    /// Every length multiplied by `scale` (the UI scale); the delay and `maxWidth` (the threshold's
    /// reference) stay.
    public func scaled(by scale: CGFloat) -> MotionTabStrip {
        var g = self
        g.openStartWidth *= scale
        g.closeEndWidth *= scale
        g.minActiveWidth *= scale
        g.minInactiveWidth *= scale
        g.pinnedWidth *= scale
        g.closingModeBelowPad *= scale
        g.closingModeTrailingPad *= scale
        return g
    }

    /// The reorder threshold for a tab `width` wide (16 x width / 200).
    public func reorderThreshold(forTabWidth width: CGFloat) -> CGFloat {
        maxWidth > 0 ? reorderThreshold * width / maxWidth : 0
    }
}
