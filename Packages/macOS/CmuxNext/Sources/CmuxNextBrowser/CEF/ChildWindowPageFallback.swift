import AppKit
import CmuxNextDesign

/// What a Chromium page needs only while it draws in its own child window (p03-rendering R3). A child
/// window sits above every view of the cmux window, so no view order puts a pane in front of it: its
/// clip shape leaves out what the panes stacked in front of its pane cover (a zoom growing over it, an
/// overlay dock's pane over a strip pane). A page hosted in the window's layer tree
/// (`CEFLayerHosting.page`) is ordered with the views, as Chrome's page view is an ordinary subview
/// (`content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm`), and needs none of it.
///
/// The layout computes nothing for this per frame: the covers are asked for here, when a child-window
/// page reads its clip, and the pane keeps its answer until its screen's stacking or frames change
/// (`PageCoverSource`). Task 053 moves the rest of the child-window path (occlusion rects, the page
/// update notification) into this file.
nonisolated enum ChildWindowPageFallback {
    /// The parts of `view` (its coordinates) the panes stacked in front of its pane cover; none for a
    /// page hosted in the layer tree (`isHosted`, a seam for tests), or outside a pane.
    @MainActor
    static func cutouts(around view: NSView,
                        isHosted: @MainActor (CEFHostView) -> Bool = { $0.layerHosting.page != nil }) -> [CGRect] {
        if let host = view as? CEFHostView, isHosted(host) { return [] }
        var ancestor = view.superview
        while let current = ancestor {
            if let source = current as? any PageCoverSource {
                let covers = source.pageCovers()
                return covers.isEmpty ? [] : covers.map { view.convert($0, from: current) }
            }
            ancestor = current.superview
        }
        return []
    }

    /// Whether the page window over `host` hides while its pane springs on the render server with the
    /// `pageSpringResizeOnce` feature (p03-rendering-036): a page in its own window is placed from the pane's
    /// frame, which a render-server spring sets at rest in its first turn, so it would show at the rest place
    /// for the whole spring. It hides through an occlusion hole over all of the host
    /// (`CEFHostView.allOcclusionRects`, the fork's way to keep a page from showing), the host shows the page's
    /// background meanwhile, and the landing's geometry update shows it again where the pane landed. On the
    /// main thread's spring frames the window follows the pane's frame; a hosted page moves with its pane.
    @MainActor
    static func hidesForSpring(_ host: CEFHostView) -> Bool {
        host.spring?.onRenderServer == true && host.drawsInChildWindow
    }
}

/// A page draws in its own window until the window's layer tree hosts it (`CEFLayerHosting.page`).
extension CEFHostView: ChildWindowContent {
    var drawsInChildWindow: Bool { layerHosting.page == nil }
}
