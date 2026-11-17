import AppKit
import CmuxNextDesign

/// The light around a zoom, for one screen: the other panes dim, and no pane moves under the dim.
///
/// - A zoom waits (``Phase/coming``): the screen shows the layout before it, whole and live, while the dim comes over
///   the other panes. No pane hears its new size in that time, so a terminal goes on drawing at the size it shows. In
///   the frame where the dim's fade is spent the panes hear their sizes, as for any layout change, and the frame that
///   shows the zoomed pane alone takes the dim away.
/// - An unzoom shows every pane at its place in one frame, the others under the dim (``Phase/going``), which fades out
///   and leaves when its fade is over.
///
/// The fade runs on the render server. This object counts its time in the layout's frame ticks: it has no timer and
/// no clock of its own, so the frame that shows a zoom, and the one that takes the dim away, are the layout's.
/// The screen owns one and tells it what happens (``ScreenContentView/zoomDim``); it keeps no reference to the screen.
@MainActor
final class PaneZoomDim {
    enum Phase {
        /// No dim shows.
        case off
        /// The dim comes over the layout before a zoom; the zoom's panes hear their sizes when its time is spent.
        case coming
        /// The dim goes over the layout an unzoom showed; it leaves when its time is spent.
        case going
    }

    private(set) var phase: Phase = .off
    /// The screen's zoom is a page that takes the whole window (``LayoutScreen/presented``), set before each update: it
    /// comes and goes with no dim.
    var presentsPage = false
    /// Seconds of frame time left in the phase.
    private var remaining: TimeInterval = 0
    /// The zoom the screen applies now gets a dim before it shows (``layoutWillChange(on:to:zoomed:structural:onCanvas:waitsForFrame:)``).
    private var comes = false
    /// The screen's waiting change gave no pane its size yet: the panes hear their sizes when the dim's time is spent.
    private var holdsSizes = false
    /// The pane an unzoom gives its place back to: the dim comes with the frame that shows that unzoom.
    private var returning: PaneID?
    /// The zoom the screen shows came with no dim (a page's, or on a canvas): its unzoom brings none either.
    private var cameUndimmed = false
    private weak var view: PaneZoomDimView?

    /// The longest the dim's fade may take, whatever the animation speed. With the frames a layout change may wait for
    /// its panes after it, a zoom shows inside 300 ms.
    static let longest: TimeInterval = 0.25
    /// A time with less than this left is spent: a fade of a whole number of frames ends on its last frame.
    static let spent: TimeInterval = 1e-6

    /// The seconds the dim's fade takes on `screen` now: the pane veil's fade, at most ``longest``. 0 when panes do not
    /// animate (Reduce Motion, pane animations off, a window out of sight): then no dim shows.
    func fade(on screen: ScreenContentView) -> TimeInterval {
        let context = screen.context
        guard !context.reduceMotion, context.animatesPaneLayout, screen.window != nil, !screen.isHiddenOrHasHiddenAncestor else { return 0 }
        return min(Motion.panes.duration(.paneDim), Self.longest)
    }

    /// `screen` is about to apply `layout` (`zoomed`: as one zoomed pane); its own layout is still the one before.
    /// A newer change, or a second zoom key, ends a dim that still shows. An unzoom of a zoom that showed brings its
    /// own dim, with the frame that shows it. A zoom of one pane gets a dim before it shows when panes animate, the
    /// root runs frames (`waitsForFrame`) and no older change still waits for its frame (the zoom then shows with that
    /// change, with no dim). A zoom on a canvas (`onCanvas`), or of a page that takes the whole window, comes with
    /// none: the canvas's camera changes in the zoom's own turn, and a page's zoom is the page's act.
    func layoutWillChange(on screen: ScreenContentView, to layout: ScreenLayout, zoomed: Bool, structural: Bool, onCanvas: Bool,
                          waitsForFrame: Bool) {
        let zooming = !screen.zoomed && zoomed
        let unzooming = screen.zoomed && !zoomed
        guard structural || zooming || unzooming else { return }
        let dimsOthers = !presentsPage && !onCanvas
        let waits = screen.frameInput.snapWaitsForContent
        let shown = screen.layout.panes
        let back = unzooming && dimsOthers && !cameUndimmed && !waits && shown.count == 1 ? shown.first : nil
        comes = zooming && structural && dimsOthers && layout.panes.count == 1 && waitsForFrame && !waits && fade(on: screen) > 0
        if comes, phase == .going {
            // A zoom while an unzoom's dim still goes takes that dim over from the strength it shows (`holdsSnap`).
            phase = .off
            remaining = 0
        } else {
            end()
        }
        if holdsSizes {
            // The change that waited behind a dim is replaced: the newer one gives its sizes itself, and the dim's time
            // was no wait for content, so its wait starts at 0.
            holdsSizes = false
            screen.frameInput.snapRefreshesWaited = 0
        }
        returning = back
        if zooming { cameUndimmed = !dimsOthers }
    }

    /// In `screen`'s pass over the layout that ``layoutWillChange(on:to:zoomed:structural:onCanvas:waitsForFrame:)`` saw,
    /// where a change that waits for its frame gives its panes their sizes ahead. A zoom that gets a dim gives
    /// none yet: its change is marked as waiting, and the dim comes over the other panes of the layout the screen
    /// still shows. Returns whether it did; false leaves the sizes to the caller.
    func holdsSnap(of screen: ScreenContentView) -> Bool {
        guard comes else { return false }
        comes = false
        let continuing = view?.superview != nil
        guard let pane = screen.layout.panes.first, let view = place(around: pane, on: screen) else {
            end()
            return false
        }
        view.fadeIn(continuing: continuing)
        phase = .coming
        remaining = fade(on: screen)
        holdsSizes = true
        // The change waits for a frame tick, as one that gave its sizes ahead does; no pane is asked yet.
        screen.frameInput.snapWaitsForContent = true
        screen.frameInput.presentationWaiting = true
        screen.frameInput.snapAwaitsPrograms = false
        screen.frameInput.snapRefreshesWaited = 0
        screen.context.requestFrames()
        return true
    }

    /// A frame tick while `screen`'s change waits: whether the dim still holds it. While the dim comes it does. In the
    /// frame where its time is spent (or where the dim went because panes stopped animating) the panes hear their
    /// sizes, and the change waits for them as any change does, with its count of waited frames at 0: the dim's time
    /// was no wait for content.
    func holdsFrame(of screen: ScreenContentView) -> Bool {
        guard holdsSizes else { return false }
        if phase == .coming, remaining > Self.spent { return true }
        holdsSizes = false
        screen.frameInput.snapRefreshesWaited = 0
        return screen.holdsSnapForContent()
    }

    /// `screen` shows its waiting change in this pass: a dim that came before a zoom leaves in that commit.
    func changeShows() {
        holdsSizes = false
        if phase == .coming { end() }
    }

    /// The pass of `screen` that shows an unzoom placed the panes: the dim shows over the others at its full strength,
    /// and goes.
    func panesPlaced(on screen: ScreenContentView) {
        guard let pane = returning else { return }
        returning = nil
        let fade = self.fade(on: screen)
        guard fade > 0, let view = place(around: pane, on: screen) else { return }
        view.fadeOut()
        phase = .going
        remaining = fade
        screen.context.requestFrames()
    }

    /// The dim's view over `screen` less `pane`'s content rect as the pane shows now, in the layout's overlay plane.
    private func place(around pane: PaneID, on screen: ScreenContentView) -> PaneZoomDimView? {
        guard let root = screen.superview as? LayoutRootView, let host = screen.context.hosts[pane], host.superview === screen else { return nil }
        let view = self.view ?? PaneZoomDimView()
        self.view = view
        view.place(in: root.overlayPlane, below: root.highlight, extent: root.convert(screen.bounds, from: screen),
                   hole: root.convert(host.contentRect, from: host))
        return view
    }

    /// Takes the dim away now: its zoom shows, a newer change or a second key came, the screen's size changed, or the
    /// screen goes out of sight. A change that still waits behind it gives its sizes at the next frame tick.
    func end() {
        view?.removeFromSuperview()
        phase = .off
        remaining = 0
        returning = nil
    }

    /// `screen`'s layout lands now (Reduce Motion turned on, the window out of sight): no motion from here on. The dim
    /// leaves, the springs settle and the canvas camera rests. A zoom that waited behind the dim shows in the frames
    /// that follow.
    func land(_ screen: ScreenContentView) {
        end()
        if screen.hasMotion || screen.resizeGesture == .landing { screen.settleMotion() }
        screen.settleCanvasCamera()
    }

    /// The dim goes (it fades out after an unzoom showed): it keeps the frames coming until it left. It is no motion
    /// of the layout: no pane moves, and what waits for the layout to land does not wait for it.
    var goes: Bool { phase == .going }

    /// One frame tick of the dim's time. A dim that goes leaves when its time is spent.
    func step(_ dt: Double) {
        guard phase != .off else { return }
        remaining -= dt
        if phase == .going, remaining <= Self.spent { end() }
    }
}
