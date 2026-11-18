import AppKit
import CmuxNextDesign

/// The panes' move at a layout change that is one commit, for one screen.
///
/// A split shows in one commit: the frame that shows it has each pane and its content at the place and size of the
/// layout after it, and no later frame lays a pane out (`ScreenContentView+SnapFrame`). This object makes that frame
/// the start of a move: each pane host whose rect changed gets animations of its layer's `position` and
/// `bounds.size` that add to the layer's value, from where the pane showed to zero, so the pane's clip goes from its
/// old rect to its new one on the render server, over content that is already final. The move makes no view and
/// puts none into another parent, and it changes no frame.
///
/// - A pane that comes starts with no room on the edge of its rect that is away from the pane that gave it its room,
///   so the two panes' edges go together.
/// - A pane that gets smaller shows its own ground beside its content until its edge is there (`PaneCommitMotion+Layers`).
/// - A pane's ring and the dividers get the same move.
/// - A second act while the panes move adds its own move: each pane goes on from where it shows, with no jump.
/// - Only content that rides moves (`NSView.paneRidesCommitMotion`): an act that changes a pane with another kind
///   of content shows in one frame, whole.
/// - A content that keeps its own old picture while its pane gets smaller (``PaneCommitMotionHolding``) hears the
///   start of its hold before a pane hears a size, and its end in the frame that ends the motion.
/// - No content is offset against its pane: a content's top leading corner is on its pane's in each frame.
///
/// The moves run on the render server. This object counts their time in the layout's frame ticks (``step(_:)``): it
/// has no timer, and the tick in which the time is spent takes the moves away. The screen's ``PaneZoomDim`` owns
/// one and tells it what happens; it keeps no reference to the screen.
@MainActor
final class PaneCommitMotion {
    /// A change whose panes move.
    enum Act {
        /// Panes came and none left.
        case split

        var spring: MotionSpring {
            switch self {
            case .split: .split
            }
        }

        /// The act that takes a screen from the panes `old` to the panes `new`; nil: the change shows in one frame.
        init?(from old: Set<PaneID>, to new: Set<PaneID>) {
            guard new.isStrictSuperset(of: old) else { return nil }
            self = .split
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
    }

    /// A spring is at rest for the eye when this part of its way is left: the frame clock ends the motion there.
    static let rest = 0.005

    private var armed: Armed?
    /// Seconds of frame time left in the motion.
    private var remaining: TimeInterval = 0
    /// One number for each act, in the keys of its animations.
    var serial = 0
    /// Each animation in flight.
    var moved: [(layer: CALayer, key: String)] = []
    /// The pane hosts that show ground strips, and the largest size each showed in this motion.
    var grounds: [ObjectIdentifier: (layer: CALayer, extent: CGSize)] = [:]
    /// The contents that keep their own old picture until the motion's end (``PaneCommitMotionHolding``), by pane host.
    var holds: [ObjectIdentifier: any PaneCommitMotionHolding] = [:]

    /// A pane still moves: the frames go on until the motion's time is spent.
    var inFlight: Bool { remaining > 0 }

    /// Whether a change of `screen` moves its panes now.
    private func moves(on screen: ScreenContentView) -> Bool {
        screen.context.movesPanesAtCommit && screen.window != nil && !screen.isHiddenOrHasHiddenAncestor
    }

    /// `screen` is about to apply `layout` (`zoomed`: as one zoomed pane); it still has the layout before. `still`:
    /// nothing can move (the root runs no frames, a canvas, a page that has the whole window). A change that came
    /// before the last one showed keeps what the screen showed before both.
    func layoutWillChange(on screen: ScreenContentView, to layout: ScreenLayout, zoomed: Bool, structural: Bool, still: Bool) {
        guard structural || screen.zoomed != zoomed else { return }
        var next = armed ?? Armed(act: nil, panes: Set(screen.layout.panes), zoomed: screen.zoomed, frames: Self.shown(screen.subviews))
        next.act = structural && !still && !next.zoomed && !zoomed ? Act(from: next.panes, to: Set(layout.panes)) : nil
        armed = next
    }

    /// `screen` is about to give its panes the sizes of the change that waits for its frame: no pane heard a size yet.
    /// Each pane that stays and gets smaller in a change that can move, and whose content keeps its own picture, starts
    /// its hold. A content that holds from an act before goes on: its hold ends with the last motion.
    func sizesWillChange(on screen: ScreenContentView) {
        guard let armed, armed.act != nil, moves(on: screen) else { return }
        for pane in armed.panes {
            guard let host = screen.context.hosts[pane], let old = armed.frames[ObjectIdentifier(host)], holds[ObjectIdentifier(host)] == nil,
                  let new = screen.paneFrames[pane]?.targetRect, new.width < old.width - 0.5 || new.height < old.height - 0.5,
                  let holder = host.content.paneCommitMotionHolder, holder.paneCommitMotionHoldKind == .ownPicture else { continue }
            holds[ObjectIdentifier(host)] = holder
            holder.beginPaneCommitMotionHold()
        }
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
    func panesPlaced(on screen: ScreenContentView) {
        guard let armed else { return }
        self.armed = nil
        guard let act = armed.act, moves(on: screen) else { return finish() }
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
        for host in coming {
            riders.append(host)
            guard let new = host.layer?.frame, let old = Self.start(of: new, among: staying) else { continue }
            changes.append(Change(host: host, old: old, new: new, comes: true))
        }
        let time = Motion.panes.spring(act.spring).settlingTime(within: Self.rest)
        guard !changes.isEmpty, time > 0, riders.allSatisfy({ $0.content.paneRidesCommitMotion }) else { return finish() }
        serial += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for change in changes {
            guard let layer = change.host.layer else { continue }
            move(layer, act.spring, origin: change.origin, size: change.size)
            showGround(beside: change)
            moveRing(of: change, act.spring)
        }
        for view in screen.dividerViews.values where !view.isHidden {
            guard let layer = view.layer else { continue }
            let new = layer.frame
            if let old = armed.frames[ObjectIdentifier(view)] {
                guard old != new else { continue }
                move(layer, act.spring, origin: CGPoint(x: old.minX - new.minX, y: old.minY - new.minY),
                     size: CGSize(width: old.width - new.width, height: old.height - new.height))
            } else if let edge = changes.lazy.compactMap({ Self.edge(of: $0, at: new) }).first {
                move(layer, act.spring, origin: edge, size: .zero)
            }
        }
        CATransaction.commit()
        remaining = max(remaining, time)
        screen.context.requestFrames()
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

    /// One frame tick of the motion's time. The tick in which the time is spent takes the moves away.
    func step(_ dt: Double) {
        guard remaining > 0 else { return }
        remaining -= dt
        if remaining <= PaneZoomDim.spent { finish() }
    }

    /// Ends the motion now: each pane, ring and divider shows at its place, and the ground strips go. The motion's
    /// time is spent, a change that shows in one frame shows, the screen's size changed, the screen goes out of
    /// sight, or panes stopped animating.
    func finish() {
        remaining = 0
        let held = Array(holds.values)
        holds = [:]
        for holder in held { holder.endPaneCommitMotionHold() }
        guard !moved.isEmpty || !grounds.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, key) in moved { layer.removeAnimation(forKey: key) }
        moved = []
        for ground in grounds.values { Self.strips(of: ground.layer).forEach { $0.removeFromSuperlayer() } }
        grounds = [:]
        CATransaction.commit()
    }
}
