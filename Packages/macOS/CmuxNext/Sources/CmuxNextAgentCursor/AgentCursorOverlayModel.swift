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
        let session = event.sessionID
        var cursor = cursors[session] ?? Cursor()
        guard !cursor.paused else { return }
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
            if event.kind == .click || event.kind == .doubleClick || event.kind == .rightClick {
                host.apply(.pulse(session: session))
            }
        case let .hidden(anchor):
            host.apply(.indicate(session: session, anchor: CGPoint(x: anchor.midX, y: anchor.midY)))
            cursor.point = nil
        case .elsewhere:
            host.apply(.hide(session: session))
            cursor.point = nil
        }
        cursors[session] = cursor
    }

    /// Called with a target the cursor no longer follows (its session's lease
    /// ended), so the visibility source stops tracking it.
    public var onUntrack: ((String) -> Void)?

    /// A tracked target's visibility changed between input events (a column
    /// scrolled, a window minimized, a tab or workspace switched): sessions
    /// whose last input went to `target` move their cursor to the new place.
    public func placementsDidChange(target: String) {
        _ = target
    }

    /// A lease frame for `session`: `nil` means the lease ended.
    public func leaseDidChange(session: String, state: AgentCursorLeaseState?) {
        guard let state else {
            if cursors.removeValue(forKey: session) != nil {
                host.apply(.remove(session: session))
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
