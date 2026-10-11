public import CmuxAgentCursor
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
    /// The resting heading of a cmux-cua cursor (tip up-left).
    public static let restingHeading = Double.pi / 4

    private struct Cursor {
        var point: CGPoint?
        var paused = false
        /// The session's last input: re-placed when its target's visibility changes.
        var lastEvent: AutomationInputEvent?
    }

    private let resolver: AgentCursorTargetResolving
    private let host: AgentCursorLayerHosting
    private let motion: GlideMotion
    private var cursors: [String: Cursor] = [:]

    public init(resolver: AgentCursorTargetResolving, host: AgentCursorLayerHosting, motion: GlideMotion = GlideMotion()) {
        self.resolver = resolver
        self.host = host
        self.motion = motion
    }

    public func render(_ event: AutomationInputEvent) {
        var cursor = cursors[event.sessionID] ?? Cursor()
        guard !cursor.paused else { return }
        let isClick = event.kind == .click || event.kind == .doubleClick || event.kind == .rightClick
        draw(event, cursor: &cursor, pulse: isClick)
        cursor.lastEvent = event
        cursors[event.sessionID] = cursor
    }

    /// Places `event`'s cursor where its target is now.
    private func draw(_ event: AutomationInputEvent, cursor: inout Cursor, pulse: Bool) {
        let session = event.sessionID
        switch resolver.placement(forTarget: event.targetID) {
        case let .visible(content, clip, zoom, magnification):
            guard let target = AgentCursorGeometry.overlayPoint(
                of: event, content: content, clip: clip, zoom: zoom, magnification: magnification
            ) else {
                return
            }
            if let from = cursor.point {
                if from != target {
                    host.apply(.glide(session: session, plan: motion.plan(
                        fromX: from.x, fromY: from.y, toX: target.x, toY: target.y, endHeading: Self.restingHeading
                    )))
                }
            } else {
                host.apply(.place(session: session, point: target))
            }
            cursor.point = target
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
            draw(event, cursor: &cursor, pulse: false)
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
