import AppKit
import CmuxNextDesign

/// The light around a zoom, for one screen: the other panes dim while the pane that zooms moves, and after an unzoom.
///
/// - A zoom shows as any layout change does: its panes hear their sizes in the key's turn. In the frame that shows
///   it the pane starts its move over the panes that it covers (``PaneCommitMotion``), and the dim comes over them
///   with a hole that goes with the pane (``Phase/zooming``). The frame that ends the move takes the dim away. No
///   frame waits for the dim. A zoom whose pane does not move shows in one frame with no dim.
/// - An unzoom shows every pane at its place in one frame, the others under the dim (``Phase/going``), which fades out
///   and leaves when its fade is over. When the pane that had the screen closes to its place (``PaneCommitMotion``),
///   the dim's hole goes with it.
///
/// The fades and the moves run on the render server. This object counts their time in the layout's frame ticks: it
/// has no timer and no clock of its own, so the frame that takes the dim away is the layout's.
/// The screen owns one and tells it what happens (``ScreenContentView/zoomDim``); it keeps no reference to the screen.
///
/// It also tells the panes when the screen shows a zoom or an unzoom, for their own zoom marks (``showMarks(on:)``).
@MainActor
final class PaneZoomDim {
    enum Phase {
        /// No dim shows.
        case off
        /// The dim comes over the panes that a zoom covers while its pane moves; it leaves when that move ends.
        case zooming
        /// The dim goes over the layout an unzoom showed; it leaves when its time is spent.
        case going
    }

    private(set) var phase: Phase = .off
    /// The screen's zoom is a page that takes the whole window (``LayoutScreen/presented``), set before each update: it
    /// comes and goes with no dim.
    var presentsPage = false { didSet { if presentsPage { owesMarks = true } } }
    /// Seconds of frame time left in the phase ``Phase/going``.
    private var remaining: TimeInterval = 0
    /// The content rect of the pane that the waiting zoom or unzoom moves, as its layout had it before, in the overlay
    /// plane's coordinates: the dim's hole starts there.
    private var holeBefore: CGRect?
    /// The pane an unzoom gives its place back to: the dim comes with the frame that shows that unzoom.
    private var returning: PaneID?
    /// The zoom the screen shows came with no dim (a page's, or on a canvas): its unzoom brings none either.
    private var cameUndimmed = false
    /// The pane whose own zoom marks show, as the last pass told the panes (``showMarks(on:)``); nil: none.
    private var marked: PaneID?
    /// The next pass that tells the zoom marks tells each pane it placed, whatever ``marked`` is: no pass told yet, or
    /// a page had the whole window since, and the pane's own state wrote its marks in that time.
    private var owesMarks = true
    private weak var view: PaneZoomDimView?
    /// The panes' move at a split, a close and a zoom: it hears what this object hears, and its time is counted with
    /// the dim's.
    let motion = PaneCommitMotion()

    /// The longest an unzoom's dim may take, whatever the pane veil's fade is. The dim's layer fades for the veil's
    /// whole time: with a veil fade above this time, an unzoom's dim leaves before its fade is at its end.
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
    /// A newer change ends a dim that goes after an unzoom. A zoom's dim stays in the turn of a second key, while its
    /// pane still moves: the pass that shows that key's change ends it. An unzoom of a zoom that showed brings its
    /// own dim, with the frame that shows it. A zoom whose pane can move (``PaneCommitMotion/zooms``) brings its dim
    /// with the frame that begins the move (``panesPlaced(on:)``). A zoom on a canvas (`onCanvas`), of a page that
    /// takes the whole window, or with a root that runs no frames (`waitsForFrame`) moves nothing and brings none:
    /// the canvas's camera changes in the zoom's own turn, and a page's zoom is the page's act.
    func layoutWillChange(on screen: ScreenContentView, to layout: ScreenLayout, zoomed: Bool, structural: Bool, onCanvas: Bool,
                          waitsForFrame: Bool) {
        motion.layoutWillChange(on: screen, to: layout, zoomed: zoomed, structural: structural, still: presentsPage || onCanvas || !waitsForFrame)
        let zooming = !screen.zoomed && zoomed
        let unzooming = screen.zoomed && !zoomed
        guard structural || zooming || unzooming else { return }
        let dimsOthers = !presentsPage && !onCanvas
        let waits = screen.frameInput.snapWaitsForContent
        let shown = screen.layout.panes
        let back = unzooming && dimsOthers && !cameUndimmed && !waits && shown.count == 1 ? shown.first : nil
        if motion.zooms, phase == .going {
            // A zoom while an unzoom's dim still goes takes that dim over from the strength it shows (`come`).
            phase = .off
            remaining = 0
        } else if phase != .zooming {
            leave()
        }
        // A second key in a zoom's move changes nothing that shows in its own turn: the pane still moves, so its dim
        // stays. The pass that shows this change takes the dim away, or lets it go from the strength it shows.
        // Where the pane that moves has its place now: a zoom's pane in the layout before, an unzoom's at its screen's size.
        holeBefore = (motion.zooms ? layout.panes.first : motion.unzooms ? shown.first : nil).flatMap { hole(of: $0, on: screen) }
        returning = back
        if zooming { cameUndimmed = !dimsOthers }
    }

    /// `screen` is about to give its panes the sizes of the change that waits for its frame: no pane heard one yet.
    /// A zoom gives its sizes in the key's turn, as any change does: no dim comes before it.
    func sizesWillChange(on screen: ScreenContentView) {
        motion.sizesWillChange(on: screen)
    }

    /// A pass of `screen` placed the panes: the panes' own zoom marks become those of the layout that this pass shows
    /// (``showMarks(on:)``), and the panes of a split, a close and a zoom start their move. In the pass that begins a
    /// zoom's move the dim comes over the panes that the zoom covers. In the pass that shows an unzoom, the dim shows
    /// over the others at its full strength, and goes.
    func panesPlaced(on screen: ScreenContentView) {
        showMarks(on: screen)
        // A zoom's dim still showed when this pass came: a second key came in the zoom's move.
        let zoomDimShowed = phase == .zooming
        let started = motion.panesPlaced(on: screen)
        if let started, started.act == .zoom {
            come(with: started.change, on: screen)
        } else if phase == .off {
            self.view?.removeFromSuperview() // a dim that a zoom took over, when that zoom shows with no move
        }
        let before = holeBefore
        holeBefore = nil
        guard let pane = returning else {
            // The pass ended the zoom's move (a split or a close in it shows in one frame): its dim goes with it.
            if zoomDimShowed, !motion.inFlight { leave() }
            return
        }
        returning = nil
        let fade = self.fade(on: screen)
        guard fade > 0, let view = place(around: pane, on: screen) else { return leave() }
        // An unzoom in a zoom's move lets that zoom's dim go from the strength it shows: no step up to its full strength.
        view.fadeOut(continuing: zoomDimShowed)
        if let before, started?.act == .unzoom {
            // The hole goes with the pane that closes to its place: the dim never covers that pane.
            let spring = PaneCommitMotion.Act.unzoom.spring
            view.moveHole(from: before) { part, origin, size in motion.move(part, spring, origin: origin, size: size) }
        }
        phase = .going
        remaining = fade
        screen.context.requestFrames()
    }

    /// The dim comes with the move of the pane that zooms: over `screen` less that pane's content rect, on the pane
    /// veil's fade, from nothing or from the strength that a dim that was going shows. Its hole goes with the pane,
    /// from the pane's content rect before the zoom, on the zoom's spring. The frame that ends the move takes the
    /// dim away (``step(_:)``).
    private func come(with zoom: PaneCommitMotion.Change, on screen: ScreenContentView) {
        let continuing = self.view?.superview != nil
        let before = holeBefore
        holeBefore = nil
        guard let view = place(around: zoom.host.pane, on: screen) else { return leave() }
        view.fadeIn(continuing: continuing)
        if let before {
            let spring = PaneCommitMotion.Act.zoom.spring
            view.moveHole(from: before) { part, origin, size in motion.move(part, spring, origin: origin, size: size) }
        }
        phase = .zooming
        remaining = 0
    }

    /// Tells the panes whether the layout that `screen` shows now has them zoomed (`PaneContentChrome`), so a pane's
    /// own zoom marks (an Exit Zoom control) change with the frame that shows the zoom or the unzoom, not with the key
    /// before it. Only a pass that shows another zoom than the pass before tells: the pane that had the marks, and
    /// each pane the pass placed. A page that has the whole window shows its pane alone whatever the zoom is: the
    /// layout says nothing in that time. The first pass of all and the first pass after a page's time tell each pane
    /// they placed (``owesMarks``): a pane can have marks that this screen's passes did not give it.
    private func showMarks(on screen: ScreenContentView) {
        guard !presentsPage else { return }
        let zoomed = screen.zoomed ? screen.layout.panes.first : nil
        guard zoomed != marked || owesMarks else { return }
        owesMarks = false
        for pane in Set(screen.paneFrames.keys).union([marked, zoomed].compactMap { $0 }) {
            (screen.context.hosts[pane]?.content as? PaneContentChrome)?.setPaneShownZoomed(pane == zoomed)
        }
        marked = zoomed
    }

    /// The dim's view over `screen` less `pane`'s content rect as the pane shows now, in the layout's overlay plane.
    private func place(around pane: PaneID, on screen: ScreenContentView) -> PaneZoomDimView? {
        guard let root = screen.superview as? LayoutRootView, let hole = hole(of: pane, on: screen) else { return nil }
        let view = self.view ?? PaneZoomDimView()
        self.view = view
        view.place(in: root.overlayPlane, below: root.highlight, extent: root.convert(screen.bounds, from: screen), hole: hole)
        return view
    }

    /// `pane`'s content rect as the pane shows on `screen` now, in the coordinates of the layout's overlay plane.
    private func hole(of pane: PaneID, on screen: ScreenContentView) -> CGRect? {
        guard let root = screen.superview as? LayoutRootView, let host = screen.context.hosts[pane], host.superview === screen else { return nil }
        return root.convert(host.contentRect, from: host)
    }

    /// Ends the dim and the panes' move now: the screen's size changed, the screen goes out of sight, or no motion
    /// goes on from here. A change that still waits for its frame then shows with no move.
    func end() {
        motion.cancel()
        holeBefore = nil
        returning = nil
        leave()
    }

    /// The pass that shows `screen`'s change begins: the panes that the change took out hide, their rings with them
    /// (`LayoutViewContext.hideRetiredShown(of:)`). A close or a zoom that moves its panes keeps them to the end of
    /// its motion, under the panes that take their room (``PaneCommitMotion/keepsDeparted(on:)``). Returns whether
    /// any hid now.
    func hidesDeparted(of screen: ScreenContentView) -> Bool {
        motion.keepsDeparted(on: screen) ? false : screen.context.hideRetiredShown(of: screen.screenID)
    }

    /// Takes the dim away now: its zoom's move ended, its fade is over, a newer change came while it went, the screen's
    /// size changed, or the screen goes out of sight. The panes' move goes on: a newer change that moves adds to it.
    /// An unzoom that waits for its frame keeps its dim to come (``returning``). A zoom's move does not end in that
    /// wait, so its dim stays for the unzoom (``PaneCommitMotion/step(_:)``); it ends only under a wait that is
    /// longer than a change's own bound.
    private func leave() {
        view?.removeFromSuperview()
        phase = .off
        remaining = 0
    }

    /// `screen`'s layout lands now (Reduce Motion turned on, the window out of sight): no motion from here on. The dim
    /// leaves, the panes' move ends, the springs settle and the canvas camera rests.
    func land(_ screen: ScreenContentView) {
        end()
        if screen.hasMotion || screen.resizeGesture == .landing { screen.settleMotion() }
        screen.settleCanvasCamera()
    }

    /// The dim goes (it fades out after an unzoom showed): it keeps the frames coming until it left. It is no motion
    /// of the layout: no pane moves, and what waits for the layout to land does not wait for it.
    /// The panes' move at a split, a close or a zoom keeps the frames coming too, until its time is spent.
    var goes: Bool { phase == .going || motion.inFlight }

    /// One frame tick of the dim's time, and of the panes' move. A dim that goes leaves when its time is spent; a
    /// zoom's dim leaves in the tick that ends the move of its pane.
    func step(_ dt: Double) {
        motion.step(dt)
        switch phase {
        case .off: return
        case .zooming: if !motion.inFlight { leave() }
        case .going:
            remaining -= dt
            if remaining <= Self.spent { leave() }
        }
    }
}
