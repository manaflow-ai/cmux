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

/// A page draws in its own window until the window's layer tree hosts it (`CEFLayerHosting.page`), and again
/// while a widget orders its page window in (`CEFPageWindowWidgets`).
extension CEFHostView: ChildWindowContent {
    var drawsInChildWindow: Bool { layerHosting.page == nil || pageWindowWidgets.isShowingPageWindow }
}

/// The per-widget fallback of an attached page (p03-rendering-046): the widgets the fork shows on the page
/// window (``CEFNativeWidgetRoute/pageWindow``: autofill, print preview) order that window in, transparent and
/// over the host view, for as long as one is open. Chrome hangs those on the Browser's widget; the page's
/// pixels, input and the rest of its native UI stay in the attached view.
///
/// While one is open, the host draws in a child window again (``CEFHostView/drawsInChildWindow``): the layout
/// moves its pane by frames, not by layer transforms a child window cannot follow, and the fork is told to
/// place the window over the host at once (`changed`), not at the next move.
@MainActor
final class CEFPageWindowWidgets {
    /// The widgets each browser of the pane shows on its page window now.
    private(set) var open: [Int32: Set<CEFNativeWidget>] = [:]
    /// Called when the page window starts or stops showing for a widget.
    var changed: (() -> Void)?

    /// Some widget keeps the page window ordered in.
    var isShowingPageWindow: Bool { !open.isEmpty }

    /// A ``CEFForkTabEvent/pageWindowWidget`` report for `browser`.
    func report(_ event: CEFPageWindowWidgetEvent, browser: Int32) {
        let wasShowing = isShowingPageWindow
        var widgets = open[browser] ?? []
        if event.shown {
            guard widgets.insert(event.widget).inserted else { return }
            CEFHostView.trackerStats.pageWindowWidgetShows += 1
        } else {
            guard widgets.remove(event.widget) != nil else { return }
        }
        open[browser] = widgets.isEmpty ? nil : widgets
        if isShowingPageWindow != wasShowing { changed?() }
    }

    /// `browser` closed: its widgets went with its window.
    func browserClosed(_ browser: Int32) {
        guard open.removeValue(forKey: browser) != nil else { return }
        if !isShowingPageWindow { changed?() }
    }
}
