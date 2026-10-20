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
    /// The name tag text per session (``AgentCursorSessionLabel``); nil or
    /// empty shows no tag.
    public typealias Labeling = (String) -> String?

    /// How long a cursor stays after its agent's last action: the cmux-cua
    /// helper's idle fade (`--idle-hide-ms 10000`, cx-ujus), so in-app and
    /// screen cursors leave together.
    public static let idleHideDelay: CFTimeInterval = 10

    private let hostLayer: CALayer
    private let color: Coloring
    private let label: Labeling
    private var cursors: [String: AgentCursorLayer] = [:]

    public init(hostLayer: CALayer, color: @escaping Coloring,
                label: @escaping Labeling = { AgentCursorSessionLabel(sessionID: $0).text }) {
        self.hostLayer = hostLayer
        self.color = color
        self.label = label
    }

    /// Sessions with a cursor layer, sorted (diagnostics).
    public var sessions: [String] {
        cursors.keys.sorted()
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
            cursor.armIdleHide(after: Self.idleHideDelay)
        case let .glide(session, plan):
            let cursor = cursor(for: session)
            cursor.root.isHidden = false
            cursor.showsIndicator = false
            let position = plan.positionAnimation()
            let rotation = plan.rotationAnimation()
            if let last = plan.samples.last {
                cursor.root.position = CGPoint(x: last.x, y: last.y)
                cursor.heading.setValue(last.heading - AgentCursorOverlayModel.restingHeading, forKeyPath: "transform.rotation.z")
            }
            rotation.values = rotation.values?.compactMap { ($0 as? Double).map { $0 - AgentCursorOverlayModel.restingHeading } }
            cursor.root.add(position, forKey: "agentCursor.glide")
            cursor.heading.add(rotation, forKey: "agentCursor.heading")
            cursor.armIdleHide(after: plan.duration + Self.idleHideDelay)
        case let .pulse(session):
            // A pulse follows its action's place or glide, which armed the idle hide.
            cursor(for: session).pulse()
        case let .caption(session, text):
            // Only a placed cursor shows a caption (the model checks it);
            // typing keeps the cursor up as any input does.
            guard let cursor = cursors[session] else { return }
            cursor.showCaption(text, scale: max(hostLayer.contentsScale, 2))
            cursor.armIdleHide(after: Self.idleHideDelay)
        case let .indicate(session, anchor):
            let cursor = cursor(for: session)
            cursor.root.removeAnimation(forKey: "agentCursor.glide")
            cursor.heading.removeAnimation(forKey: "agentCursor.heading")
            cursor.root.position = anchor
            cursor.root.isHidden = false
            cursor.showsIndicator = true
            cursor.armIdleHide(after: Self.idleHideDelay)
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
        let cursor = AgentCursorLayer(color: color(session), name: label(session), scale: max(hostLayer.contentsScale, 2))
        hostLayer.addSublayer(cursor.root)
        cursors[session] = cursor
        return cursor
    }
}
