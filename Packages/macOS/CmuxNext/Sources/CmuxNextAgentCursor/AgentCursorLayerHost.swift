public import CmuxAgentCursor
public import QuartzCore

/// Draws agent cursors as CALayers inside one host layer: the window's
/// `OverlayPlane` layer (y-down, layout-root coordinates, kept above
/// Chromium pages by `WindowOverlayLayer`). Travel is one keyframe animation
/// per action on the render server; there is no timer and no per-frame work
/// here, and nothing runs while no agent acts.
public final class AgentCursorLayerHost: AgentCursorLayerHosting {
    /// Fill color per session. The App passes `AgentCursorPalette.forSession`
    /// once the vendored package carries it (cmux-cua v0.8.3).
    public typealias Coloring = (String) -> CGColor

    private let hostLayer: CALayer
    private let color: Coloring
    private var cursors: [String: AgentCursorLayer] = [:]

    public init(hostLayer: CALayer, color: @escaping Coloring) {
        self.hostLayer = hostLayer
        self.color = color
    }

    /// Sessions with a cursor layer, sorted (diagnostics).
    public var sessions: [String] {
        []
    }

    /// The cursor layer of a session (tests and diagnostics).
    public func cursorLayer(for session: String) -> AgentCursorLayer? {
        cursors[session]
    }

    public func apply(_ command: AgentCursorCommand) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch command {
        case let .place(session, point):
            let cursor = cursor(for: session)
            cursor.root.position = point
            cursor.root.isHidden = false
            cursor.showsIndicator = false
        case let .glide(session, plan):
            let cursor = cursor(for: session)
            cursor.root.isHidden = false
            cursor.showsIndicator = false
            let position = CursorAnimation.position(plan)
            let rotation = CursorAnimation.rotation(plan)
            if let last = plan.samples.last {
                cursor.root.position = CGPoint(x: last.x, y: last.y)
                cursor.root.setValue(last.heading - AgentCursorOverlayModel.restingHeading, forKeyPath: "transform.rotation.z")
            }
            rotation.values = rotation.values?.compactMap { ($0 as? Double).map { $0 - AgentCursorOverlayModel.restingHeading } }
            cursor.root.add(position, forKey: "agentCursor.glide")
            cursor.root.add(rotation, forKey: "agentCursor.heading")
        case let .pulse(session):
            cursor(for: session).pulse()
        case let .indicate(session, anchor):
            let cursor = cursor(for: session)
            cursor.root.removeAnimation(forKey: "agentCursor.glide")
            cursor.root.removeAnimation(forKey: "agentCursor.heading")
            cursor.root.position = anchor
            cursor.root.isHidden = false
            cursor.showsIndicator = true
        case let .hide(session):
            cursors[session]?.root.isHidden = true
        case let .setPaused(session, paused):
            // Never create a cursor for a pause: lease frames reach every
            // content, and the model refuses input while paused anyway.
            cursors[session]?.isPaused = paused
        case let .remove(session):
            cursors.removeValue(forKey: session)?.root.removeFromSuperlayer()
        }
    }

    private func cursor(for session: String) -> AgentCursorLayer {
        if let existing = cursors[session] {
            return existing
        }
        let cursor = AgentCursorLayer(color: color(session))
        hostLayer.addSublayer(cursor.root)
        cursors[session] = cursor
        return cursor
    }
}
