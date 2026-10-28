import AppKit
import CmuxNextDesign

/// A Chromium page in a pane that springs (a split, a close, a zoom) with the `pageSpringResizeOnce` feature,
/// as a terminal holds its final grid (`TerminalSurfaceView+PaneMotion`):
/// - `once`: the page takes the size its pane rests at when the spring starts, held at its top-left, and
///   keeps it until the landing, which resizes nothing more. A hosted page's frame at that size joins the
///   fence of the turn that resized it, so it shows with the spring's first frame, as
///   Chrome's surface synchronization shows a tab's new size with its browser frame (`cc/layers/deadline_policy.h`).
/// - `perFrame`: the page resizes with the pane on every frame.
/// In both, the gaps beside the page show its background (Chrome's gutter,
/// `content/browser/renderer_host/delegated_frame_host.h`), and a page in its own window hides while its pane
/// shows a render-server move (`ChildWindowPageFallback.hidesForSpring`).
extension CEFTabContentView: PaneMotionTargeting {
    func paneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor {
        guard let resizing = springPlacement?.pageResizing, let host = shownHost else { return .top }
        host.setPageSpring(true)
        switch resizing.mode() {
        case .once: springHold = SpringPageHold(size: bounds.size, sizeChange: sizeChange)
        case .perFrame: springHold = nil
        }
        applySpringGutter()
        layoutContent()
        return .top
    }

    /// The pane's shared host view while this tab shows it; nil while another tab of the pane does.
    private var shownHost: CEFHostView? {
        guard let host = tab?.host.hostView, host.superview === self else { return nil }
        return host
    }

    /// The container moved (another pane, another window, none): a hold from the old pane ends, since that
    /// pane's landing never reaches it, and the new pane is found once (``springPlacement``). A page window
    /// over it hides only while the new pane shows a render-server move.
    func placeInPane() {
        springPlacement = nil
        endSpringResize()
        let placement = enclosingRestingPlacement
        springPlacement = placement?.pageResizing != nil ? placement : nil
        let moving = springPlacement?.showsRenderMove ?? false
        for case let host as CEFHostView in subviews { host.paneRenderMoveDidChange(moving) }
    }

    /// A layout on a spring the page has not heard of: the first frame of a main-thread spring resizes the
    /// pane before the spring's start reaches its content, and a tab shown mid-spring missed the start. The
    /// page takes the spring's rest size here, as at the start (`RestingPlacement.restContentSizeChange`, the
    /// rest less the content's current size). No ancestor walk: without the feature ``springPlacement`` is nil.
    func joinSpringResize() {
        guard let placement = springPlacement, springHold == nil, let host = shownHost, !host.isOnPageSpring,
              placement.isOnLayoutSpring, let change = placement.restContentSizeChange else { return }
        _ = paneMotionWillRest(sizeChange: change)
    }

    /// The pane's spring landed (``paneMotionDidSettle()``), or the container left the pane: the page takes
    /// the container's area again (the held size, when the spring landed at its rest).
    func endSpringResize() {
        let host = shownHost
        guard springHold != nil || host?.isOnPageSpring == true else { return }
        springHold = nil
        applySpringGutter()
        layoutContent()
        host?.setPageSpring(false)
    }

    /// While a held page is smaller than the container (a pane shrinking on the main thread's frames), the gap
    /// beside it shows the page's background, as the host view under it does (`CEFHostView.pageBackdrop`).
    private func applySpringGutter() {
        let host = shownHost
        let color = springHold == nil || host?.pageSeeThrough != false ? nil : host?.pageBackdrop
        guard layer?.backgroundColor != color else { return }
        layer?.backgroundColor = color
    }
}
