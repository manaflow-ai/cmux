import AppKit

// cmux: real Messages blurs and darkens the header's avatar and name pill with the transcript under
// an open thread or reply view (thread-open-esc reference: the avatar 237 -> 103). The vendored
// window view keeps its thread layer (ThreadBackdrop, a live blur and tint, and the thread's rows)
// in its own layer tree, under the in-pane header (`PaneHeaderView`, AppKit views above that tree),
// so the header stayed sharp. As the morph and compose layers are hosted on their own (HostView
// install), the thread layer's CALayer moves to `threadHost`, a layer host above the header and
// below the selection, morph, field and compose hosts: the backdrop blurs and darkens the live
// header (its glass, title and avatar as drawn) on its own open and close curves, and the field
// stays above it. The thread layer view stays the window view's subview (frames, hit tests and
// scale walks are unchanged); only where its layer draws moves.

extension HostView {
    /// Moves the window view's thread layer into `threadHost`. The thread layer is the window view's
    /// subview right after `clip` (WindowView init: clip, threadLayer, header, compose, ...), whose
    /// first subview (`threadDim`) holds ThreadBackdrop's root layer; anything else is left in place.
    func liftThreadLayer(_ demo: MessagesWindowView) {
        guard let i = demo.subviews.firstIndex(where: { $0 === demo.clip }), demo.subviews.indices.contains(i + 1) else { return }
        let thread = demo.subviews[i + 1]
        guard thread !== demo.header, thread !== demo.compose, thread !== demo.morphView,
              let dim = thread.subviews.first, dim.subviews.isEmpty,
              let backdrop = dim.layer.sublayers?.first, !(backdrop.sublayers ?? []).isEmpty else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        threadHost.root.addSublayer(thread.layer)
        CATransaction.commit()
    }
}
