import AppKit
import CmuxNextDesign

/// A Chromium page in a pane that springs (a split, a close, a zoom) with the `pageSpringResizeOnce` feature
/// (p03-rendering-036), as a terminal holds its final grid (`TerminalSurfaceView+PaneMotion`):
/// - `once`: the page takes the size its pane rests at when the spring starts, held at its top-left, and
///   keeps it until the landing, which resizes nothing more. A hosted page's frame at that size joins the
///   window's fence of the turn (`ResizeFenceTurn`), so it shows with the spring's first frame, as Chrome's
///   surface synchronization shows a tab's new size with its browser frame (`cc/layers/deadline_policy.h`).
/// - `perFrame`: the page resizes with the pane on every frame, each resize of a hosted page fenced.
/// In both, the gaps beside the page show its background (Chrome's gutter,
/// `content/browser/renderer_host/delegated_frame_host.h`), and a page in its own window hides until a
/// render-server spring lands (`ChildWindowPageFallback.hidesForSpring`).
extension CEFTabContentView: PaneMotionTargeting {
    func paneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor {
        guard let placement = enclosingRestingPlacement, let resizing = placement.pageResizing, let host = tab?.host.hostView,
              host.superview === self else { return .top }
        host.setSpring(CEFHostView.PageSpring(fence: resizing.fence, onRenderServer: placement.isOnRenderSpring))
        switch resizing.mode() {
        case .once: springHold = SpringPageHold(size: bounds.size, sizeChange: sizeChange)
        case .perFrame: springHold = nil
        }
        applySpringGutter()
        layoutContent()
        return .top
    }

    /// A layout on a spring the page has not heard of: the first frame of a main-thread spring resizes the
    /// pane before the spring's start reaches its content, and a tab shown mid-spring missed the start. The
    /// page takes the spring's rest size here, as at the start (`RestingPlacement.restContentSizeChange`).
    /// One walk of the ancestors per layout while no spring holds the page.
    func joinSpringResize() {
        guard springHold == nil, let host = tab?.host.hostView, host.superview === self, host.spring == nil,
              let placement = enclosingRestingPlacement, placement.pageResizing != nil, placement.isOnLayoutSpring,
              let change = placement.restContentSizeChange else { return }
        _ = paneMotionWillRest(sizeChange: change)
    }

    /// The pane's spring landed (``paneMotionDidSettle()``): the page takes the container's area again (the
    /// held size, when the spring landed at its rest), and a page in its own window shows again.
    func endSpringResize() {
        if springHold != nil {
            springHold = nil
            applySpringGutter()
            layoutContent()
        }
        if let host = tab?.host.hostView, host.superview === self { host.setSpring(nil) }
    }

    /// While a held page is smaller than the container (a pane shrinking on the main thread's frames), the gap
    /// beside it shows the page's background, as the host view under it does (`CEFHostView.pageBackdrop`).
    private func applySpringGutter() {
        let host = tab?.host.hostView
        let color = springHold == nil || host?.pageSeeThrough != false ? nil : host?.pageBackdrop
        guard layer?.backgroundColor != color else { return }
        layer?.backgroundColor = color
    }
}

extension CEFHostView {
    /// A pane spring as the page sees it (``CEFHostView/spring``).
    struct PageSpring {
        /// The window's fence of the turn, which a hosted page's resize joins.
        let fence: ResizeFenceTurn
        /// The pane's frame is already at rest and Core Animation shows it springing there.
        let onRenderServer: Bool
    }
}
