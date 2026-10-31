public import CmuxAgentCursor
import CmuxNextDesign
public import CoreGraphics

/// The host's lease state as the cursor needs it (automation-lease.md).
public enum AgentCursorLeaseState: Sendable, Equatable {
    case driving, paused, userDriving
}

/// Turns published input events into cursor commands for one window.
/// `AgentCursorPublisher` (the one entry point) calls `render`; lease frames
/// call `leaseDidChange`.
@MainActor
public final class AgentCursorOverlayModel: AgentCursorRendering {
    /// The resting heading of the arrow (tip up-left): the direction from its
    /// tip to its body's center, 63° below the x axis for the leaning arrow
    /// (``AgentCursorLayer/arrowPath``), so a glide turns it along travel.
    public static let restingHeading = 63 * Double.pi / 180

    /// A move this soon (ms) after the session's previous move is a sample
    /// of a streamed human path (plans/cmux-next/human-mouse-DESIGN.md): the
    /// cursor follows it instead of starting a new glide.
    static let followWindowMs = 100.0
    /// The longest one follow segment lasts (s): a late sample catches up.
    static let maxFollowSeconds = 0.05

    private struct Cursor {
        var point: CGPoint?
        var paused = false
        /// The session's last input: re-placed when its target's visibility changes.
        var lastEvent: AutomationInputEvent?
        /// What the session is typing (the keystroke caption).
        var caption = AgentKeystrokeCaption()
        /// `tMs` of the session's last move, while it may be streaming a path.
        var lastMoveMs: Double?
    }

    private let resolver: AgentCursorTargetResolving
    private let host: AgentCursorLayerHosting
    private let motion: GlideMotion
    /// Movement animates (the a274 motion gate: off under Reduce Motion);
    /// when false every placement snaps.
    private let animatesMovement: @MainActor () -> Bool
    private var cursors: [String: Cursor] = [:]

    /// - Parameter animatesMovement: read per input; nil (the default) reads
    ///   the app's motion policy (`Motion.animatesMovement`). Tests pin it.
    public init(resolver: AgentCursorTargetResolving, host: AgentCursorLayerHosting, motion: GlideMotion = GlideMotion(),
                animatesMovement: (@MainActor () -> Bool)? = nil) {
        self.resolver = resolver
        self.host = host
        self.motion = motion
        self.animatesMovement = animatesMovement ?? { Motion.cursor.animatesMovement }
    }

    public func render(_ event: AutomationInputEvent) {
        render(event, typing: nil)
    }

    /// One input with what it types (`typing`, type and key events): the
    /// cursor goes to the field when the host measured it, and the
    /// keystroke caption shows the text beside the cursor.
    public func render(_ event: AutomationInputEvent, typing: AgentTyping?) {
        var cursor = cursors[event.sessionID] ?? Cursor()
        guard !cursor.paused else { return }
        let isClick = event.kind == .click || event.kind == .doubleClick || event.kind == .rightClick
        draw(event, cursor: &cursor, pulse: isClick)
        if let text = cursor.caption.apply(kind: event.kind, typing: typing, tMs: event.tMs), !text.isEmpty {
            // A cursor that is not drawn here (a hidden or other target, or
            // typing before any placed input) shows no caption.
            if cursor.point != nil {
                host.apply(.caption(session: event.sessionID, text: text))
            }
        }
        // A typed input with no measured field leaves the cursor where it was.
        if AgentCursorGeometry.pagePoint(of: event) != nil || cursor.lastEvent == nil {
            cursor.lastEvent = event
        }
        cursors[event.sessionID] = cursor
    }

    /// Places `event`'s cursor where its target is now.
    /// A drag glides to the grab, then on to the drop in one plan; `replay`
    /// (a visibility change, not a new input) puts it at the drop at once.
    private func draw(_ event: AutomationInputEvent, cursor: inout Cursor, pulse: Bool, replay: Bool = false) {
        let session = event.sessionID
        switch resolver.placement(forTarget: event.targetID) {
        case let .visible(content, clip, zoom, magnification):
            guard var target = AgentCursorGeometry.overlayPoint(
                of: event, content: content, clip: clip, zoom: zoom, magnification: magnification
            ) else {
                return
            }
            var drop = AgentCursorGeometry.dropPoint(of: event, content: content, clip: clip, zoom: zoom, magnification: magnification)
            if replay, let end = drop {
                target = end
                drop = nil
            }
            let streamed = streamGap(event, cursor: &cursor, replay: replay)
            host.apply(.confine(session: session, bounds: clip))
            if !animatesMovement() {
                // Reduce Motion: the cursor appears where the input lands.
                host.apply(.place(session: session, point: drop ?? target))
            } else if let from = cursor.point, let gap = streamed, drop == nil {
                if from != target {
                    host.apply(.glide(session: session, plan: motion.follow(
                        fromX: from.x, fromY: from.y, toX: target.x, toY: target.y,
                        duration: min(gap, Self.maxFollowSeconds), heading: Self.restingHeading
                    )))
                }
            } else if let from = cursor.point {
                var plan: GlidePlan?
                if from != target {
                    plan = motion.plan(fromX: from.x, fromY: from.y, toX: target.x, toY: target.y, endHeading: Self.restingHeading)
                }
                if let drop, drop != target {
                    let carry = motion.plan(fromX: target.x, fromY: target.y, toX: drop.x, toY: drop.y, endHeading: Self.restingHeading)
                    if plan == nil { plan = carry } else { plan?.samples += carry.samples }
                }
                if let plan { host.apply(.glide(session: session, plan: plan)) }
            } else {
                host.apply(.place(session: session, point: target))
                if let drop, drop != target {
                    host.apply(.glide(session: session, plan: motion.plan(
                        fromX: target.x, fromY: target.y, toX: drop.x, toY: drop.y, endHeading: Self.restingHeading
                    )))
                }
            }
            cursor.point = drop ?? target
            if pulse {
                host.apply(.pulse(session: session))
            }
        case let .hidden(anchor):
            host.apply(.indicate(session: session, anchor: CGPoint(x: anchor.midX, y: anchor.midY)))
            cursor.point = nil
        case .elsewhere:
            host.apply(.hide(session: session))
            cursor.point = nil
        }
    }

    /// The seconds since the session's previous move when `event` continues
    /// a streamed path (a move within `followWindowMs` of a move), else nil.
    /// Records the move's time; any other input ends the stream.
    private func streamGap(_ event: AutomationInputEvent, cursor: inout Cursor, replay: Bool) -> Double? {
        guard !replay else { return nil }
        guard event.kind == .move else {
            cursor.lastMoveMs = nil
            return nil
        }
        defer { cursor.lastMoveMs = event.tMs }
        guard let last = cursor.lastMoveMs, event.tMs >= last, event.tMs - last <= Self.followWindowMs else { return nil }
        return (event.tMs - last) / 1000
    }

    /// Called with a target the cursor no longer follows (its session's lease
    /// ended), so the visibility source stops tracking it.
    public var onUntrack: ((String) -> Void)?

    /// A tracked target's visibility changed between input events (a column
    /// scrolled, a window minimized, a tab or workspace switched): sessions
    /// whose last input went to `target` move their cursor to the new place.
    public func placementsDidChange(target: String) {
        for session in cursors.keys.sorted() {
            guard var cursor = cursors[session], !cursor.paused,
                  let event = cursor.lastEvent, event.targetID == target else { continue }
            draw(event, cursor: &cursor, pulse: false, replay: true)
            cursors[session] = cursor
        }
    }

    /// A lease frame for `session`: `nil` means the lease ended.
    public func leaseDidChange(session: String, state: AgentCursorLeaseState?) {
        guard let state else {
            if let ended = cursors.removeValue(forKey: session) {
                host.apply(.remove(session: session))
                if let target = ended.lastEvent?.targetID,
                   !cursors.values.contains(where: { $0.lastEvent?.targetID == target }) {
                    onUntrack?(target)
                }
            }
            return
        }
        var cursor = cursors[session] ?? Cursor()
        let paused = state != .driving
        if cursor.paused != paused {
            cursor.paused = paused
            host.apply(.setPaused(session: session, paused: paused))
        }
        cursors[session] = cursor
    }
}
