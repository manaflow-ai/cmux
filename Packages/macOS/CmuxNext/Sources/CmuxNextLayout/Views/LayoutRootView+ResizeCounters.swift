import AppKit

extension LayoutRootView {
    /// Reconcile passes of this root's screens, cumulative (`debug.layout_counters` `screen_reconciles`): a
    /// window live-resize event of a screen at rest adds none (`ScreenContentView.resizeInPlace()`,
    /// window-live-resize-bench.py). Read a delta.
    public var screenReconciles: Int { screenViews.values.reduce(0) { $0 + $1.reconcilePasses } }

    /// Resizes of this root's screens that set only the changed rects (`ScreenContentView.resizeInPlace()`),
    /// cumulative (`debug.layout_counters` `screen_resizes_in_place`). Read a delta.
    public var screenResizesInPlace: Int { screenViews.values.reduce(0) { $0 + $1.resizesInPlace } }
}
