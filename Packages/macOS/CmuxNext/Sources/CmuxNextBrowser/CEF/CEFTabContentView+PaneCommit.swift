import AppKit
import CmuxNextDesign

/// A layout change that shows in one commit (a split, a close, a zoom, an unzoom) tells the shown Chromium page its new
/// size in the change's own turn. The page takes that size only in the pass that shows the change (the pane's content
/// takes its final size there, or at the motion's end when it holds its own picture), and that resize joins the
/// window's resize fence (``CEFLayerHosting/paneCommitWillResize(_:)``): the render server shows the commit with the
/// page's first frame at its new size, so the zoomed page shows whole in the frame that shows the zoom, not its old
/// frame at the old size beside the page's backdrop.
///
/// The fence waits in the render server, not on the main thread, so the page is ready for the layout at once: the
/// change waits for no report of the page and shows at the next frame tick, as before.
extension CEFTabContentView: PaneCommitSurface {
    func commitWillResize(by change: CGSize, ready: @escaping @MainActor () -> Void) {
        defer { ready() }
        guard window != nil, let tab, tab.host.hostView.superview === self else { return }
        tab.host.hostView.layerHosting.paneCommitWillResize(change != .zero)
    }
}
