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

    /// The cursor layer of a session (tests and diagnostics).
    public func cursorLayer(for session: String) -> AgentCursorLayer? {
        cursors[session]
    }

    public func apply(_ command: AgentCursorCommand) {
        _ = command
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
