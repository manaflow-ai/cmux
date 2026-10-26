public import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// What a Chromium page needs only while it draws in its own child window (p03-rendering R3). A child
/// window sits above every view of the cmux window, so no view order puts a pane in front of it and no
/// layer mask reaches it: the fork's page tracker (`CmuxParentViewTracker`) asks the host view for a clip
/// shape (`-cmuxClipPath`) and for holes (`-cmuxOcclusionRects`), and re-places the page window when the
/// window asks its pages to re-read them (`pagesNeedUpdate`). The clip shape leaves out what the panes
/// stacked in front of its pane cover (a zoom growing over it, an overlay dock's pane over a strip pane).
/// A page hosted in the window's layer tree (`CEFLayerHosting.page`) is ordered with the views, as
/// Chrome's page view is an ordinary subview (`content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm`),
/// and needs none of the cutouts; the fork falls back to this path for a page whose hosting it refused.
///
/// This file is the only place that names the fork's clip and occlusion selectors and the window's page
/// update request (DC8b). Every other file asks through `NSWindow.updateBrowserPageGeometry(force:)`,
/// `observePageUpdates(of:_:)` and `CEFHostView.childWindowPage`.
///
/// The layout computes nothing for this per frame: the covers are asked for here, when a child-window
/// page reads its clip, and the pane keeps its answer until its screen's stacking or frames change
/// (`PageCoverSource`).
nonisolated enum ChildWindowPageFallback {
    /// Posted (object: the `NSWindow`) to make every page of that window re-apply its geometry, clip and
    /// occlusion. A page re-applies only when something it reads changed since the fork last read it,
    /// unless `userInfo[forceKey]` is true.
    fileprivate static let pagesNeedUpdate = Notification.Name("CmuxBrowserChildWindowPagesNeedUpdate")
    /// `userInfo` key of `pagesNeedUpdate`: true makes every page re-apply even where nothing it reads
    /// changed (a page window that something other than the fork moved, such as an Accessibility client,
    /// goes back over its host).
    fileprivate static let forceKey = "force"

    /// One page update request: the window it is for and whether every page re-applies.
    struct PageUpdate {
        let window: NSWindow?
        let force: Bool
    }

    /// Calls `handler` on each page update request of `window` (nil: of every window) until the returned
    /// observation is released.
    @MainActor
    static func observePageUpdates(of window: NSWindow?, center: NotificationCenter = .default,
                                   _ handler: @escaping @MainActor (PageUpdate) -> Void) -> MainActorObservation {
        MainActorObservation(pagesNeedUpdate, object: window, center: center, read: { note in
            PageUpdate(window: note.object as? NSWindow, force: note.userInfo?[forceKey] as? Bool ?? false)
        }, handler)
    }

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

public extension NSWindow {
    /// Asks every Chromium page of this window to re-apply its geometry, clip and occlusion: after the
    /// window's own native overlays over its content moved (`BrowserWindowOcclusionProviding`), a clip
    /// or corner changed with no page move, or the window moved or resized by any means (drag,
    /// Accessibility clients such as Rectangle, display or Space changes, fullscreen, deminiaturize).
    /// A page tells the fork only when what it reads changed since its last read; `force` makes every
    /// page re-apply (a page window moved by another app).
    func updateBrowserPageGeometry(force: Bool = false, center: NotificationCenter = .default) {
        center.post(name: ChildWindowPageFallback.pagesNeedUpdate, object: self,
                    userInfo: force ? [ChildWindowPageFallback.forceKey: true] : nil)
    }
}

/// A page draws in its own window until the window's layer tree hosts it (`CEFLayerHosting.page`).
extension CEFHostView: ChildWindowContent {
    var drawsInChildWindow: Bool { layerHosting.page == nil }
}

/// What the fork's tracker reads from one host view, and what it read last
/// (`CEFHostView.childWindowPage`).
@MainActor
final class ChildWindowPageGeometry {
    weak var view: CEFHostView?
    /// The window's page update requests, while the view is in a window.
    private var pageUpdates: MainActorObservation?
    /// What the fork read on its last update of this page (`-cmuxOcclusionRects`);
    /// nil before its first read and after a window change.
    private var readGeometry: CEFHostGeometry?

    /// The last clip shape and what it was worked out from. The fork reads
    /// the clip and the occlusion rects on every geometry update, several
    /// times per display frame while a pane moves, and also on window moves,
    /// key changes and occlusion changes that move nothing. The path
    /// operations run only when the bounds, a clip or a cutout changed; the
    /// walk of the ancestors that finds those still runs on every read.
    private var clipMemo: ClipMemo?

    struct ClipMemo {
        let inputs: CEFClipShape.Inputs
        let path: CGPath?
        /// `path` for the fork; nil when the page is a plain rect, and when it
        /// shows nothing: a page clipped away entirely is hidden by an occlusion
        /// hole over all of it (`occlusionRects()`), the fork's documented way
        /// to keep a page from showing.
        let bezier: NSBezierPath?
    }

    /// The view moved to another window or out of one: the fork has read nothing in it yet.
    func windowDidChange() {
        readGeometry = nil
        guard let window = view?.window else {
            pageUpdates = nil
            return
        }
        pageUpdates = ChildWindowPageFallback.observePageUpdates(of: window) { [weak self] update in
            self?.pagesNeedUpdate(force: update.force)
        }
    }

    /// The fork read the occlusion rects: it reads these first on every update of a shown page.
    func forkDidReadOcclusion() {
        guard let view else { return }
        readGeometry = CEFHostGeometry(of: view)
    }

    /// The window asks its pages to re-apply their geometry (the divider lines
    /// or the sidebar moved, a clip or corner changed, the window moved). The
    /// fork is told only when what it reads changed since its last read: on a
    /// motion frame the static pages have nothing to re-place, re-clip or
    /// re-mask (Lawrence 2026-10-23: splits lag more with Chromium pages).
    /// `force`: a page window moved by something other than the fork must be
    /// put back over its host even though the host did not move.
    func pagesNeedUpdate(force: Bool) {
        guard let view else { return }
        let now = CEFHostGeometry(of: view)
        guard force || readGeometry != now else {
            CEFHostView.trackerStats.geometrySkips += 1
            return
        }
        view.postGeometryChange()
        // The fork updates inside the post; a hidden or not yet created page reads nothing
        // there, so what it was told is recorded here (a still hidden page has nothing new).
        readGeometry = now
    }

    /// The clip shape now, from the memo while its inputs hold.
    func clipShape() -> ClipMemo {
        let started = CEFTrackerStats.now()
        defer { CEFHostView.trackerStats.clipSeconds += CEFTrackerStats.now() - started }
        let inputs = view.map { CEFClipShape.Inputs(around: $0) } ?? CEFClipShape.Inputs(bounds: .zero, clips: [])
        if let clipMemo, clipMemo.inputs == inputs {
            CEFHostView.trackerStats.clipHits += 1
            return clipMemo
        }
        CEFHostView.trackerStats.clipBuilds += 1
        let path = inputs.path
        let bezier = CEFClipShape.showsNothing(path) ? nil : path.map { NSBezierPath(cgPath: $0) }
        let memo = ClipMemo(inputs: inputs, path: path, bezier: bezier)
        clipMemo = memo
        return memo
    }

    /// The chrome's rects plus the window's interactive overlays over the
    /// view, in the view's coordinates; all of it when the clip shows nothing.
    func occlusionRects() -> [CGRect] {
        guard let view else { return [] }
        if CEFClipShape.showsNothing(clipShape().path), !view.bounds.isEmpty { return [view.bounds] }
        var rects = view.occlusionRects
        if let provider = view.window as? any BrowserWindowOcclusionProviding {
            for rect in provider.browserOcclusionRectsInWindow {
                let local = view.convert(rect, from: nil).intersection(view.bounds)
                if !local.isNull, !local.isEmpty { rects.append(local) }
            }
        }
        return CEFHostView.outermost(rects)
    }
}

/// The fork's selectors on the host view (`CmuxParentViewTracker`); their names are the fork's API.
extension CEFHostView {
    /// Read by the fork (NSArray of NSValue NSRect) on every geometry update,
    /// so window rects convert at the current position.
    @objc func cmuxOcclusionRects() -> NSArray {
        Self.trackerStats.occlusionReads += 1
        childWindowPage.forkDidReadOcclusion()
        return childWindowPage.occlusionRects().map { NSValue(rect: $0) } as NSArray
    }

    /// Read by the fork on every geometry update: the pane's rounded clip and
    /// the window's rounded corners, so no square page corner shows past
    /// either. Nil when the page is a plain rect. The same path object comes
    /// back until the shape changes; the fork only reads it (it maps a copy to
    /// screen coordinates).
    @objc func cmuxClipPath() -> NSBezierPath? {
        Self.trackerStats.clipReads += 1
        layerHosting.trackerDidRead()
        return childWindowPage.clipShape().bezier
    }
}
