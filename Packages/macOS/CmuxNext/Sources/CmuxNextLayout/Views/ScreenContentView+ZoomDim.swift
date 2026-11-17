import AppKit
import CmuxNextDesign

/// The dim around a zoom (``PaneZoomDim``): the screen starts it, counts its time in frame ticks and ends it.
extension ScreenContentView {
    /// The seconds the dim's fade takes now: the pane veil's fade, at most ``PaneZoomDim/longest``. 0 when panes do
    /// not animate (Reduce Motion, pane animations off, a window out of sight): then no dim shows.
    var zoomDimFade: TimeInterval {
        guard !context.reduceMotion, context.animatesPaneLayout, window != nil, !isHiddenOrHasHiddenAncestor else { return 0 }
        return min(Motion.panes.duration(.paneDim), PaneZoomDim.longest)
    }

    /// A zoom of `pane` waits for its frame: the dim comes over the other panes of the layout the screen still shows,
    /// and the zoom shows when the dim's fade is over (``heldSnapAwaitsContent()``).
    func beginZoomDim(around pane: PaneID) {
        let fade = zoomDimFade, continuing = zoomDim.view?.superview != nil
        guard fade > 0, frameInput.snapWaitsForContent, let view = placeZoomDim(around: pane) else { return endZoomDim() }
        view.fadeIn(continuing: continuing)
        (zoomDim.phase, zoomDim.remaining) = (.coming, fade)
    }

    /// The frame that shows an unzoom placed the panes: the dim shows over the others at its full strength and goes.
    func beginUnzoomDim() {
        guard let pane = zoomDim.returning else { return }
        zoomDim.returning = nil
        let fade = zoomDimFade
        guard fade > 0, let view = placeZoomDim(around: pane) else { return }
        view.fadeOut()
        (zoomDim.phase, zoomDim.remaining) = (.going, fade)
        context.requestFrames()
    }

    /// The dim's view over this screen less `pane`'s content rect as the pane shows now, in the layout's overlay plane.
    private func placeZoomDim(around pane: PaneID) -> PaneZoomDimView? {
        guard let root = superview as? LayoutRootView, let host = context.hosts[pane], host.superview === self else { return nil }
        let view = zoomDim.view ?? PaneZoomDimView()
        zoomDim.view = view
        view.place(in: root.overlayPlane, below: root.highlight, extent: root.convert(bounds, from: self),
                   hole: root.convert(host.contentRect, from: host))
        return view
    }

    /// Takes the dim away now: its zoom shows, a newer change or a second key came, or the screen goes out of sight.
    func endZoomDim() {
        zoomDim.view?.removeFromSuperview()
        zoomDim = PaneZoomDim()
    }

    /// One frame tick of the dim's time. A dim that goes leaves when its fade is over. Returns whether a dim shows.
    func stepZoomDim(_ dt: Double) -> Bool {
        guard zoomDim.phase != .none else { return false }
        zoomDim.remaining -= dt
        if zoomDim.phase == .going, zoomDim.remaining <= 0 { endZoomDim() }
        return zoomDim.phase != .none
    }
}
