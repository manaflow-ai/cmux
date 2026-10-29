import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// What the fork's page tracker (`CmuxParentViewTracker`) reads from a host view while the fork has a
/// page window over it (p03-rendering R3). A child window sits above every view of the cmux window, so
/// no view order puts a pane in front of it and no layer mask reaches it: the tracker asks the host view
/// for a clip shape (`-cmuxClipPath`) and for holes (`-cmuxOcclusionRects`), and re-places the page
/// window when the window asks its pages to (`ChildPageGeometryRegistry`). The clip shape leaves out what the
/// panes stacked in front of its pane cover (a zoom growing over it, an overlay dock's pane over a strip pane).
///
/// A page hosted in the window's layer tree (`CEFLayerHosting.page`) draws with the views, as Chrome's
/// page view is an ordinary subview (`content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm`),
/// so it needs none of the cutouts. Its page window stays over it, transparent, and takes its input
/// (`ChromiumHostPageView.InputTarget.pageWindow`), so the tracker still places, clips and holes it:
/// only the cutouts wait on hosting now, and the rest goes with that window when task 045 attaches
/// Chromium's view in the host view.
///
/// This file is the only place that names the fork's clip and occlusion selectors (DC8b).
///
/// The layout computes nothing for this per frame: the covers are asked for here, when a child-window
/// page reads its clip, and the pane keeps its answer until its screen's stacking or frames change
/// (`PageCoverSource`).
nonisolated enum ChildWindowPageFallback {
    /// The parts of `view` (its coordinates) the panes stacked in front of its pane cover; none for a
    /// page hosted in the layer tree (`isHosted`, a seam for tests), or outside a pane.
    @MainActor
    static func cutouts(around view: NSView,
                        isHosted: @MainActor (CEFHostView) -> Bool = { $0.layerHosting.drawsWithViews }) -> [CGRect] {
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

    /// Whether the page window over `host` hides while its pane shows a render-server move with the
    /// `pageSpringResizeOnce` feature (`RestingPlacement.showsRenderMove`): a page in its own
    /// window is placed from the pane's frame, which a render-server spring sets at rest in its first turn, so it
    /// would show at the rest place for the whole spring. It hides through an occlusion hole over all of the host
    /// (`ChildWindowPageGeometry.occlusionRects()`, the fork's way to keep a page from showing) in the turn the spring starts,
    /// the host shows the page's background meanwhile (`CEFHostView.pageBackdrop`), and the geometry update when
    /// the move lands or the main thread takes it back orders it in where the pane is. A hosted page moves with
    /// its pane and never hides. A page in its own window has no last frame the app can show: the window server
    /// leaves the GPU process's pixels out of an app's capture without the Screen Recording grant
    /// (`NSWindow.compositedImage`), so the page's own background stands in for it.
    @MainActor
    static func hidesForSpring(_ host: CEFHostView) -> Bool {
        host.isOnRenderMove && host.drawsInChildWindow
    }
}

/// A page draws in its own window until the window's layer tree hosts it (`CEFLayerHosting.page`) or the
/// shown tab's Chromium view is attached in the host view (`CEFLayerHosting.attachedPages`), and again
/// while a widget orders its page window in (`CEFPageWindowWidgets`).
extension CEFHostView: ChildWindowContent {
    var drawsInChildWindow: Bool { !layerHosting.drawsWithViews || pageWindowWidgets.isShowingPageWindow }
}

/// The per-widget fallback of an attached page: the widgets the fork shows on a Chromium
/// window's page window (``CEFNativeWidgetRoute/pageWindow``: autofill, print preview) order that window in,
/// transparent, ignoring the mouse and over the host view, for as long as one is open. Chrome hangs those on
/// the Browser's widget; the page's pixels, input and the rest of its native UI stay in the attached view.
///
/// The state is per Chromium window, as the fork orders in a window, not a tab: the runtime gives a show to
/// the host that owns the reported window (`CEFRuntime` `.pageWindowWidget`). While one is open, the host draws
/// in a child window again (``CEFHostView/drawsInChildWindow``): the layout moves its pane by frames, not by
/// layer transforms a child window cannot follow, and the fork is told to place the window over the host at
/// once (`changed`), not at the next move.
@MainActor
final class CEFPageWindowWidgets {
    /// A browser's widgets on one Chromium window's page window.
    nonisolated struct Owner: Hashable, Sendable {
        var window: Int32
        var browser: Int32
    }

    /// The fork kinds (``CEFPageWindowWidgetEvent/kind``, raw) each owner shows now.
    private(set) var open: [Owner: Set<Int>] = [:]
    /// Called when the page window starts or stops showing for a widget.
    var changed: (() -> Void)?

    /// Some widget keeps a page window ordered in over this host.
    var isShowingPageWindow: Bool { !open.isEmpty }

    /// A ``CEFForkTabEvent/pageWindowWidget`` report of `browser` on Chromium window `window`.
    func report(_ event: CEFPageWindowWidgetEvent, window: Int32, browser: Int32) {
        let owner = Owner(window: window, browser: browser)
        let wasShowing = isShowingPageWindow
        var kinds = open[owner] ?? []
        if event.shown {
            guard kinds.insert(event.kind).inserted else { return }
            CEFHostView.trackerStats.pageWindowWidgetShowsByKind[event.kind, default: 0] += 1
        } else {
            guard kinds.remove(event.kind) != nil else { return }
        }
        open[owner] = kinds.isEmpty ? nil : kinds
        if isShowingPageWindow != wasShowing { changed?() }
    }

    /// `browser` closed: its widgets went with it, on every window.
    func browserClosed(_ browser: Int32) {
        let wasShowing = isShowingPageWindow
        open = open.filter { $0.key.browser != browser }
        if isShowingPageWindow != wasShowing { changed?() }
    }
}

extension CEFRuntime {
    /// A ``CEFForkTabEvent/pageWindowWidget`` report. The fork orders in the reported window's page window, so a
    /// show goes to the host that owns that window (a popup tab still in its opener's window is the opener
    /// host's). A close goes to every host, as the tab may have moved windows since; only the holder changes.
    func pageWindowWidgetReported(_ event: CEFPageWindowWidgetEvent, window: Int32, browser: Int32) {
        for host in hosts.values where !event.shown || host.owns(window: window) {
            host.hostView.pageWindowWidgets.report(event, window: window, browser: browser)
        }
    }

    /// `browser` closed: no host keeps a page window in for its widgets.
    func pageWindowWidgetsBrowserClosed(_ browser: Int32) {
        for host in hosts.values { host.hostView.pageWindowWidgets.browserClosed(browser) }
    }
}

/// What the fork's tracker reads from one host view, and what it read last
/// (`CEFHostView.childWindowPage`).
@MainActor
final class ChildWindowPageGeometry {
    weak var view: CEFHostView?
    /// The view's place in its window's page update requests (`ChildPageGeometryRegistry`), while the
    /// view is in a window.
    private var pageUpdates: ChildPageGeometryRegistry.Registration?
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
        guard let view, let window = view.window else {
            pageUpdates = nil
            return
        }
        pageUpdates = ChildPageGeometryRegistry.of(window).register { [weak self] force in
            self?.pagesNeedUpdate(force: force) ?? false
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
    /// put back over its host even though the host did not move. Returns whether the fork was told.
    @discardableResult
    func pagesNeedUpdate(force: Bool) -> Bool {
        guard let view else { return false }
        let now = CEFHostGeometry(of: view)
        guard force || readGeometry != now else {
            CEFHostView.trackerStats.geometrySkips += 1
            return false
        }
        view.postGeometryChange()
        // The fork updates inside the post; a hidden or not yet created page reads nothing
        // there, so what it was told is recorded here (a still hidden page has nothing new).
        readGeometry = now
        return true
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
    /// view, in the view's coordinates; all of it when the clip shows nothing or a pane spring hides the page
    /// (`ChildWindowPageFallback.hidesForSpring`).
    func occlusionRects() -> [CGRect] {
        guard let view else { return [] }
        if ChildWindowPageFallback.hidesForSpring(view) || CEFClipShape.showsNothing(clipShape().path), !view.bounds.isEmpty {
            return [view.bounds]
        }
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
