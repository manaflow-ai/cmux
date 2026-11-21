#if DEBUG || CMUX_BENCH_HOOKS
import AppKit

extension PaneHostView {
    /// Where this pane IS now, in its superview's coordinates: the frame of its layer's presentation layer, cut by
    /// its mask's presentation frame. A pane's move at a split, a close, a zoom and an unzoom is animations on that
    /// layer (`PaneCommitMotion`), and the view's frame has the end's value from the frame that shows the act: the
    /// view's frame goes to the end at once, this rect goes with the pane. With no presentation layer it is the
    /// layer's own frame. The read copies the layer: `debug.motion`'s trace reads it one time for each pane in each
    /// sample, so a trace's own cost grows with the panes. Nothing else reads it.
    var shownNow: CGRect {
        var live = layer.map { ($0.presentation() ?? $0).frame } ?? frame
        if let mask = layer?.mask {
            live = live.intersection((mask.presentation() ?? mask).frame.offsetBy(dx: live.minX, dy: live.minY))
        }
        return live.isNull ? .zero : live
    }
}
#endif
