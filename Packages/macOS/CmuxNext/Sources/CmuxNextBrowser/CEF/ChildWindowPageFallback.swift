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
}

/// A page draws in its own window until the window's layer tree hosts it (`CEFLayerHosting.page`).
extension CEFHostView: ChildWindowContent {
    var drawsInChildWindow: Bool { layerHosting.page == nil }
}
