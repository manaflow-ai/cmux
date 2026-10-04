public import CmuxAgentCursor
public import CoreGraphics

/// What the overlay layer host draws. The host owns the CALayers (one cursor
/// per session, in the window's OverlayPlane above Chromium pages); this
/// model owns no layers and no timers.
public enum AgentCursorCommand: Equatable, Sendable {
    /// First input of a session: show its cursor at `point`, no travel.
    case place(session: String, point: CGPoint)
    /// Travel along `plan` (one keyframe animation on the render server).
    case glide(session: String, plan: GlidePlan)
    /// Click feedback at the cursor's current point.
    case pulse(session: String)
    /// The target is hidden: point at its tab chip or column edge.
    case indicate(session: String, anchor: CGPoint)
    /// The target is not in this window.
    case hide(session: String)
    /// The person paused or took over: draw the cursor as an outline, still.
    case setPaused(session: String, paused: Bool)
    /// The lease ended.
    case remove(session: String)
}

@MainActor
public protocol AgentCursorLayerHosting: AnyObject {
    func apply(_ command: AgentCursorCommand)
}

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
        case let .visible(content, magnification):
            guard let target = AgentCursorGeometry.overlayPoint(of: event, content: content, magnification: magnification) else {
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
