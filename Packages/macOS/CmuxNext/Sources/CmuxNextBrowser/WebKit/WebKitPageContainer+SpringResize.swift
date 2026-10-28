import AppKit
import CmuxNextDesign

/// A WebKit page in a pane that springs (a split, a close, a zoom) with the `pageSpringResizeOnce` feature,
/// as a Chromium page does (`CEFTabContentView+SpringResize`): with `once`, the web view
/// takes the size its pane rests at when the spring starts, held at its top-left, so WebKit lays the page out
/// once, not on every frame; the gap beside it while the pane is larger shows the document's own background
/// (``pageBackdrop``, Chrome's gutter, `content/browser/renderer_host/delegated_frame_host.h`), and nothing over a
/// see-through page. WebKit commits its own layer tree at the new size, so no fence joins. `perFrame` resizes
/// it with the pane, as without the feature. An attached Web Inspector or a device emulation owns the web
/// view's frame: no hold then.
extension WebKitPageContainer: PaneMotionTargeting, PaneMotionSettling {
    func paneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor {
        guard let resizing = springPlacement?.pageResizing, resizing.mode() == .once, emulation == nil, pageAlone, let page else { return .top }
        let hold = SpringPageHold(size: bounds.size, sizeChange: sizeChange)
        springHold = hold
        page.autoresizingMask = []
        let held = hold.rect(in: bounds, flipped: isFlipped)
        if page.frame != held { page.frame = held }
        layer?.backgroundColor = pageBackdrop
        return .top
    }

    func paneMotionDidSettle() {
        endSpringHold()
    }

    /// The container moved (another pane, another window, none): a hold from the old pane ends, since that
    /// pane's landing never reaches it, and the new pane is found once (``springPlacement``).
    func placeInPane() {
        springPlacement = nil
        endSpringHold()
        let placement = enclosingRestingPlacement
        springPlacement = placement?.pageResizing != nil ? placement : nil
        if springPlacement != nil { needsPageBackdrop?() }
    }

    /// The first frame of a main-thread spring resizes the pane before the spring's start reaches its content:
    /// the page takes the spring's rest size here, as at the start (`RestingPlacement.restContentSizeChange`, the
    /// rest less the content's current size). No ancestor walk: without the feature ``springPlacement`` is nil.
    func joinSpringResize() {
        guard let placement = springPlacement, placement.isOnLayoutSpring, let change = placement.restContentSizeChange else { return }
        _ = paneMotionWillRest(sizeChange: change)
    }

    /// The spring landed, the container left its pane, or the inspector or an emulation took the web view's
    /// frame: the web view takes the container's area again (the held size, when the spring landed at its rest).
    func endSpringHold() {
        guard springHold != nil else { return }
        springHold = nil
        layer?.backgroundColor = nil
        guard let page else { return }
        page.autoresizingMask = [.width, .height]
        if pageAlone, emulation == nil, page.frame != bounds { page.frame = bounds }
    }
}
