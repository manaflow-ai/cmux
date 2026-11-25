import AppKit
import CmuxNextDesign

/// The panes' move at a layout change that is one commit, for one screen.
///
/// A split, a close, a zoom or an unzoom shows in one commit: the frame that shows it has each pane and its content
/// at the place and size of the layout after it, and no later frame lays a pane out
/// (`ScreenContentView+SnapFrame`). This object makes that frame the start of a move: each pane host whose rect
/// changed gets animations of its layer's `position` and `bounds.size` that add to the layer's value, from where the
/// pane showed to zero, so the pane's clip goes from its old rect to its new one on the render server, over content
/// that is already final. The move puts no view into another parent and changes no frame. It makes no view, but
/// for the one that shows an unzoom's last frame.
///
/// - A pane that comes starts with no room on the edge of its rect that is away from the pane that gave it its room,
///   so the two panes' edges go together.
/// - A pane that gets smaller shows its own ground beside its content until its edge is there (`PaneCommitMotion+Layers`).
/// - A pane's ring and the dividers get the same move.
/// - A pane that a close took out, or that a zoom covers, does not move: it stays as it shows, under the panes that
///   take its room, and hides in the frame that ends the motion (``keepsDeparted(on:)``).
/// - A pane that moves in a window with one plain sheet colour has it under its whole cell (`PaneCommitMotion+Sheet`).
/// - Under several panes that move with no such ground, a pane shows only past an edge of each (`PaneCommitMotion+Cover`).
/// - An unzoom's pane closes from its screen's size to its place over the panes that come back, which do not move.
///   Its last frame shows at its old size under its moving clip (`PaneCommitMotion+Unzoom`); with no last frame
///   and no picture of its own the unzoom shows in one frame.
/// - A second act while the panes move adds its own move: each pane goes on from where it shows, with no jump.
/// - Only content that rides moves (`NSView.paneRidesCommitMotion`): an act that changes a pane with another kind
///   of content shows in one frame, whole.
/// - A content that keeps its own old picture while its pane gets smaller (``PaneCommitMotionHolding``) hears the
///   start of its hold before a pane hears a size, and its end in the frame that ends the motion.
/// - No content is offset against its pane: a content's top leading corner is on its pane's in each frame.
///
/// The moves run on the render server. This object counts their time in the layout's frame ticks (``step(_:)``): it
/// has no timer, and the tick in which the time is spent takes the moves away. The screen's ``PaneZoomDim`` owns
/// one and tells it what happens; it keeps no strong reference to the screen.
@MainActor
final class PaneCommitMotion {
    /// A change whose panes move.
    enum Act {
        /// Panes came and none left.
        case split
        /// Panes left and none came.
        case close
        /// One pane takes its screen: it grows over the panes that it covers, which stay as they show under it.
        case zoom
        /// The pane that had its screen closes to its place over the panes that come back, which show at their places.
        case unzoom

        var spring: MotionSpring {
            switch self {
            case .split: .split
            case .close: .paneClose
            case .zoom: .zoom
            case .unzoom: .unzoom
            }
        }

        /// The act that takes a screen from the panes `old` to the panes `new`; nil: the change shows in one frame.
        init?(from old: Set<PaneID>, to new: Set<PaneID>) {
            if new.isStrictSuperset(of: old) { self = .split } else if old.isStrictSuperset(of: new) { self = .close } else { return nil }
        }
    }

    /// One pane host in an act: where its layer showed before the act, and where the act's layout puts it.
    struct Change {
        let host: PaneHostView
        let old: CGRect
        let new: CGRect
        /// The act brought the pane: `old` is where it starts, with no room.
        var comes = false

        /// How far the layer's origin is from its place when the move starts, and how much larger it is.
        var origin: CGPoint { CGPoint(x: old.minX - new.minX, y: old.minY - new.minY) }
        var size: CGSize { CGSize(width: old.width - new.width, height: old.height - new.height) }
    }

    /// What the screen showed when a change came, kept until the pass that shows the change.
    private struct Armed {
        var act: Act?
        let panes: Set<PaneID>
        let zoomed: Bool
        /// Each shown subview's layer frame (the pane hosts and the dividers).
        let frames: [ObjectIdentifier: CGRect]
        /// ``cancel()`` came while this change waited: `frames` are not where the panes show now, so no change that
        /// comes before the pass moves from them.
        var still = false
    }

    /// The frame clock ends the motion when this part of the spring's way is left: where the spring's animation ends
    /// too (`Motion.springAnimation`), so the count cuts no animation before its own end.
    static let rest = 0.002

    private var armed: Armed?
    /// Seconds of frame time left in the motion. An unzoom's dim reads it: the dim ends with the motion (`PaneZoomDim`).
    private(set) var remaining: TimeInterval = 0
    /// The frame ticks that a motion whose time is spent stayed for the pass of a change that waits (``step(_:)``).
    private var overtime = 0
    /// One number for each act, in the keys of its animations.
    var serial = 0
    /// The speed of this motion's springs. Nil: the app's setting. A test reads the motion at another speed by this.
    var speed: MotionSpeed?
    /// Each animation in flight.
    var moved: [(layer: CALayer, key: String)] = []
    /// The pane hosts that show ground strips, and the largest size each showed in this motion.
    var grounds: [ObjectIdentifier: (layer: CALayer, extent: CGSize)] = [:]
    /// The contents that keep their own old picture until the motion's end (``PaneCommitMotionHolding``), by pane host,
    /// each with that host: the content's view can leave its pane before the end (a tab that closes), the host stays.
    var holds: [ObjectIdentifier: (host: PaneHostView, holder: any PaneCommitMotionHolding)] = [:]
    /// The hosts of the panes that a close took out, under every other pane until the motion's end, each with the
    /// `zPosition` that its layer had.
    var under: [(host: PaneHostView, z: CGFloat)] = []
    /// The hosts that show the window's ground under their content in this motion (`PaneCommitMotion+Sheet`): each with
    /// its layer's old colour, its copy of the window's picture, and its plain ground when that is a layer in its card.
    var sheets: [(host: PaneHostView, color: CGColor?, picture: CALayer?, plain: CALayer?)] = []
    /// The hosts that show only past an edge of each pane over them, each with its window's facts (`PaneCommitMotion+Cover`).
    var covers: [ObjectIdentifier: (host: PaneHostView, frame: CGRect, window: CGRect, acts: [Int])] = [:]
    /// The dividers whose lines an unzoom holds back to the motion's end (`PaneCommitMotion+Lines`).
    var lateLines: [DividerHandleView] = []
    /// The window's picture that the copies show, as it was read at the motion's first act, and its screen.
    var shownPicture: WindowStillPicture?
    weak var pictured: ScreenContentView?
    /// The last frame of an unzoom's pane, from the turn that gives the sizes to the pass that shows the unzoom.
    var taken: Taken?
    /// The view that shows an unzoom's last frame over its pane's content.
    var lastFrame: NSView?
    /// The host that an unzoom put above the other panes, with the `zPosition` that its layer had.
    var raised: (host: PaneHostView, z: CGFloat)?
    /// The hosts under the moving pane that show only outside it until the motion's end (`PaneCommitMotion+Under`).
    var cuts: [ObjectIdentifier: PaneHostView] = [:]
    /// Hides the panes that a close took out (``keepsDeparted(on:)``); ``finish()`` runs it.
    private var departs: (@MainActor () -> Void)?
    /// The pass that shows a close began and did not place its panes yet: what the close took out still shows.
    private var passBegan = false

    /// A pane still moves: the frames go on until the motion's time is spent.
    var inFlight: Bool { remaining > 0 }

    /// Whether a change of `screen` moves its panes now.
    private func moves(on screen: ScreenContentView) -> Bool {
        screen.context.movesPanesAtCommit && screen.window != nil && !screen.isHiddenOrHasHiddenAncestor
    }

    /// `screen` is about to apply `layout` (`zoomed`: as one zoomed pane); it still has the layout before. `still`:
    /// nothing can move (the root runs no frames, a canvas, a page that has the whole window). A change that came
    /// before the last one showed keeps what the screen showed before both. A zoom moves its pane when it is the only
    /// change that waits and one pane of the layout before takes the screen; an unzoom moves the pane that had the
    /// screen when it is the only change that waits and each pane that showed stays.
    func layoutWillChange(on screen: ScreenContentView, to layout: ScreenLayout, zoomed: Bool, structural: Bool, still: Bool) {
        guard structural || screen.zoomed != zoomed else { return }
        let alone = armed == nil
        var next = armed ?? Armed(act: nil, panes: Set(screen.layout.panes), zoomed: screen.zoomed, frames: Self.shown(screen.subviews))
        let panes = Set(layout.panes)
        if !structural || still || next.still {
            next.act = nil
        } else if next.zoomed {
            next.act = alone && !zoomed && next.panes.count == 1 && panes.isStrictSuperset(of: next.panes) ? .unzoom : nil
        } else if zoomed {
            next.act = alone && panes.count == 1 && next.panes.isStrictSuperset(of: panes) ? .zoom : nil
        } else {
            next.act = Act(from: next.panes, to: panes)
        }
        armed = next
    }

    /// The change that waits for its frame is a zoom that can move its pane.
    var zooms: Bool { armed?.act == .zoom }
    /// The change that waits for its frame is an unzoom that can move its pane.
    var unzooms: Bool { armed?.act == .unzoom }
    /// A change waits for the frame that shows it.
    var waits: Bool { armed != nil }
    /// The change that waits for its frame is an act (a split, a close, a zoom or an unzoom), with the move on or off.
    var acts: Bool { armed?.act != nil }

    /// `screen` is about to give its panes the sizes of the change that waits for its frame: no pane heard a size yet.
    /// Each pane that stays and gets smaller in a change that can move, and whose content keeps its own picture, starts
    /// its hold. A content that holds from an act before goes on: its hold ends with the last motion. An unzoom's
    /// pane that holds no picture of its own gives its last frame here, one time (`PaneCommitMotion+Unzoom`).
    func sizesWillChange(on screen: ScreenContentView) {
        guard let armed, let act = armed.act, moves(on: screen) else { return }
        for pane in armed.panes {
            guard let host = screen.context.hosts[pane], let old = armed.frames[ObjectIdentifier(host)], holds[ObjectIdentifier(host)] == nil,
                  let new = screen.paneFrames[pane]?.targetRect, new.width < old.width - 0.5 || new.height < old.height - 0.5,
                  let holder = host.content.paneCommitMotionHolder, holder.paneCommitMotionHoldKind == .ownPicture else { continue }
            holds[ObjectIdentifier(host)] = (host: host, holder: holder)
            holder.beginPaneCommitMotionHold()
        }
        guard act == .unzoom, taken == nil, let host = armed.panes.first.flatMap({ screen.context.hosts[$0] }) else { return }
        if holds[ObjectIdentifier(host)] == nil { taken = Self.takeLastFrame(of: host) }
    }

    /// The pass that shows `screen`'s change begins, before it places the panes. Whether the panes that the change
    /// took out stay on the screen: at a close and at a zoom that can move they do, as they show, so the panes that
    /// take their room grow over them and not over the window's backdrop. ``finish()`` hides them: at the motion's
    /// end, or in this same pass when the change shows in one frame after all. A zoom's panes are not torn down: the
    /// screen keeps them for the unzoom (`LayoutViewContext.Retirement.zoom`).
    func keepsDeparted(on screen: ScreenContentView) -> Bool {
        guard let act = armed?.act, act == .close || act == .zoom, moves(on: screen) else { return false }
        passBegan = true
        departs = { [weak screen] in
            guard let screen, screen.context.hideRetiredShown(of: screen.screenID) else { return }
            screen.context.afterCommit { [weak screen] in screen?.releaseDeparted() }
        }
        return true
    }

    /// For a probe's note: that each of `riders` rides, or the class of the top view of each one that does not.
    private static func ride(of riders: [PaneHostView]) -> String {
        let stops = riders.map(\.content).filter { !$0.paneRidesCommitMotion }
        let kinds = Set(stops.map { content in content.paneCommitMotionTop.map { "\(type(of: $0))" } ?? "no top view in \(type(of: content))" })
        return kinds.isEmpty ? "each rides: true" : "each rides: false, the top view that does not ride: \(kinds.sorted().joined(separator: ", "))"
    }

    private static func shown(_ views: [NSView]) -> [ObjectIdentifier: CGRect] {
        var frames: [ObjectIdentifier: CGRect] = [:]
        for view in views where !view.isHidden && view.alphaValue > 0 {
            if let layer = view.layer { frames[ObjectIdentifier(view)] = layer.frame }
        }
        return frames
    }

    /// A pass of `screen` placed the panes and the dividers. The pass that shows a change starts its move, or, for a
    /// change that shows in one frame, ends a motion in flight: its panes are at their places in that frame.
    /// Returns the pane that a zoom or an unzoom moves from this pass on, for the dim; nil: no such move starts here.
    @discardableResult
    func panesPlaced(on screen: ScreenContentView) -> (act: Act, change: Change)? {
        guard let armed else {
            placePictures() // a pass with no act can give a pane a new place: its copy of the window's picture stays where the picture is
            return nil
        }
        self.armed = nil
        overtime = 0
        passBegan = false
        let last = taken
        taken = nil
        guard let act = armed.act, moves(on: screen) else {
            // Only an act gets a note: a change of no act is not a move that did not come, and a record has few places.
            if let act = armed.act { MotionTrace.note("layout.commit: \(act) in one frame (the panes move at a commit: false)") }
            finish()
            return nil
        }
        var staying: [Change] = [], coming: [PaneHostView] = []
        for pane in screen.paneFrames.keys {
            guard let host = screen.context.hosts[pane], host.superview === screen, !host.isHidden, let layer = host.layer else { continue }
            if let old = armed.frames[ObjectIdentifier(host)] {
                staying.append(Change(host: host, old: old, new: layer.frame))
            } else {
                coming.append(host)
            }
        }
        var changes = staying.filter { $0.old != $0.new }
        var riders = changes.map(\.host)
        // An unzoom's other panes show at their places from this frame, with no move: they need not ride.
        for host in act == .unzoom ? [] : coming {
            riders.append(host)
            guard let new = host.layer?.frame, let old = Self.start(of: new, among: staying) else { continue }
            changes.append(Change(host: host, old: old, new: new, comes: true))
        }
        let time = spring(act.spring).settlingTime(within: Self.rest)
        // A close moves when each pane that it took out still shows on this screen: a pane that went to another screen
        // would leave the window's backdrop where its neighbours grow. A zoom moves when the panes that still show
        // are the tiled panes that it covers and no other: a floating pane that goes with the zoom goes in one frame.
        let leaving = act == .split || act == .unzoom ? [] : screen.subviews.compactMap { $0 as? PaneHostView }.filter { $0.isLeaving && !$0.isHidden }
        let gone = armed.panes.subtracting(screen.layout.panes), kept = Set(leaving.map(\.pane))
        let covered = act == .split || act == .unzoom || (act == .close ? kept.isSuperset(of: gone) : kept == gone)
        // An unzoom moves when its one pane has its old picture for the room that its clip still shows (its last frame,
        // or its own hold), and its screen has no floating pane: the pane goes above each other pane of its screen.
        let closes = act != .unzoom || (changes.count == 1 && screen.baseGeometry.floatingCards.isEmpty
            && (last?.host === changes[0].host || changes[0].host.holdsContentForMove))
        // A window's picture that changed in the move: the copies show the old one, so this act shows in one frame.
        guard !changes.isEmpty, time > 0, covered, closes, pictureStays, riders.allSatisfy({ $0.content.paneRidesCommitMotion }) else {
            MotionTrace.note("layout.commit: \(act) in one frame (panes that change: \(changes.count), time: \(time), covered: \(covered), "
                + "closes: \(closes), the window's picture stays: \(pictureStays), \(Self.ride(of: riders)))")
            finish()
            return nil
        }
        MotionTrace.note("layout.commit: \(act) moves \(changes.count) panes for \(time) s")
        serial += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dropLastFrame() // a second act in an unzoom's time: no old picture shows over a new layout
        keepUnder(leaving)
        showSheet(under: changes, on: screen)
        for change in changes {
            guard change.host.layer != nil else { continue }
            move(change, act.spring)
            showGround(beside: change)
            moveRing(of: change, act.spring)
            moveClip(of: change, act.spring)
        }
        // The panes under the one pane that moves over them: a zoom's covered panes, an unzoom's others, a close's
        // panes taken out when one neighbour takes their room. Several moving panes have no one hole: those show as before.
        let others = act == .unzoom ? coming + staying.map(\.host).filter { $0 !== changes[0].host } : leaving
        if act == .unzoom {
            // The others: the panes that come back, or, in a zoom's move, the panes that it still kept under.
            closeOver(changes[0], last: last, others: others, act.spring)
        }
        cut(act != .split && changes.count == 1 ? others : [], by: changes[0], act.spring)
        cover(changes.count == 1 ? [] : others, under: changes, act.spring) // one pane that moves: the cut above
        for view in screen.dividerViews.values where !view.isHidden {
            guard let layer = view.layer else { continue }
            let new = layer.frame
            if let old = armed.frames[ObjectIdentifier(view)] {
                guard old != new else { continue }
                move(layer, act.spring, origin: CGPoint(x: old.minX - new.minX, y: old.minY - new.minY),
                     size: CGSize(width: old.width - new.width, height: old.height - new.height))
            } else if act == .unzoom {
                holdLine(of: view, under: changes[0])
            } else if let edge = changes.lazy.compactMap({ Self.edge(of: $0, at: new) }).first {
                move(layer, act.spring, origin: edge, size: .zero)
            }
        }
        CATransaction.commit()
        remaining = max(remaining, time)
        screen.context.requestFrames()
        return act == .zoom || act == .unzoom ? (act: act, change: changes[0]) : nil
    }

    /// Where a pane that comes into `rect` starts: with no room, on the edge of `rect` that is away from the pane
    /// that gave it its room (the one of `staying` that had the most of `rect`). The edge between the two then goes
    /// with that pane's edge. Nil: no pane had that room, or it is on no side of `rect`; the pane shows at once.
    private static func start(of rect: CGRect, among staying: [Change]) -> CGRect? {
        var giver: Change?
        var most: CGFloat = 0
        for change in staying {
            let shared = change.old.intersection(rect)
            let area = shared.isNull ? 0 : shared.width * shared.height
            if area > most { (giver, most) = (change, area) }
        }
        guard let now = giver?.new else { return nil }
        if now.maxX <= rect.minX + 1 { return CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height) }
        if now.minX >= rect.maxX - 1 { return CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height) }
        if now.maxY <= rect.minY + 1 { return CGRect(x: rect.minX, y: rect.maxY, width: rect.width, height: 0) }
        if now.minY >= rect.maxY - 1 { return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 0) }
        return nil
    }

    /// One frame tick of the motion's time. The tick in which the time is spent takes the moves away, but not under a
    /// change that waits for its frame: the pass that shows that change ends the motion or adds to it
    /// (``panesPlaced(on:)``). The frame clock steps before that pass, and a change can wait for its panes' surfaces,
    /// so without this the first act's panes would show at rest for those ticks: a zoom's covered panes with no dim
    /// and each ring. The motion stays as long as a change can wait (`ScreenContentView.longestCommitWait` ticks and the
    /// tick that shows it), then its time ends it: a change whose pass never comes keeps no motion.
    func step(_ dt: Double) {
        guard remaining > 0 else { return }
        guard pictureStays else { return finish() } // the window's picture, tint or place changed: the copies show the old one
        // A probe's count while `debug.motion` records: one sample for each frame tick with a move in flight (the
        // layout's springs give none in a move: no pane is on one), its value the animations on the layers.
        if MotionTrace.isEnabled { MotionTrace.sample("layout.commit", Double(moved.count)) }
        if armed != nil, remaining - dt <= PaneZoomDim.spent, overtime <= ScreenContentView.longestCommitWait {
            overtime += 1
            return
        }
        remaining -= dt
        if remaining <= PaneZoomDim.spent { finish() }
    }

    /// No change that waits for its frame moves from here, and the motion ends now (``finish()``): the screen's size
    /// changed, the screen goes out of sight or away, or panes stopped animating. What the screen showed before the
    /// change is not where its panes show now, so a change that comes before that one's pass does not move either.
    func cancel() {
        if let act = armed?.act { MotionTrace.note("layout.commit: \(act) in one frame (cancelled before its frame)") }
        armed?.act = nil
        armed?.still = true
        taken = nil
        finish()
    }

    /// Ends the motion now: each pane, ring and divider shows at its place, the ground strips, the window's colour
    /// under a pane and an unzoom's last frame go, and the panes that a close took out hide. The motion's time is spent, or a change that shows in one
    /// frame shows.
    func finish() {
        remaining = 0
        overtime = 0
        let held = Array(holds.values)
        holds = [:]
        for hold in held { endHold(hold.holder, of: hold.host) }
        // Between the begin of a close's pass and its panes' placement, what it took out shows.
        let hide = passBegan ? nil : departs
        showLines()
        guard hide != nil || !moved.isEmpty || !grounds.isEmpty || !under.isEmpty || !cuts.isEmpty || !sheets.isEmpty || lastFrame != nil || raised != nil else { return }
        // One transaction, and the hide is first in it: no commit takes the ground from the panes over a pane that still shows.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let hide {
            departs = nil
            hide()
        }
        for (layer, key) in moved { layer.removeAnimation(forKey: key) }
        moved = []
        covers = [:]
        for ground in grounds.values { Self.strips(of: ground.layer).forEach { $0.removeFromSuperlayer() } }
        grounds = [:]
        for (host, z) in under { host.layer?.zPosition = z }
        under = []
        uncutAll()
        hideSheets()
        dropLastFrame()
        lower()
        CATransaction.commit()
    }
}
