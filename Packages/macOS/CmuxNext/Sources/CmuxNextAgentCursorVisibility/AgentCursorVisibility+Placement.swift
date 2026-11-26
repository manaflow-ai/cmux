public import CmuxNextAgentCursor
public import CoreGraphics

extension AgentCursorVisibility {
    /// What the cursor host of `window` draws (`AgentCursorTargetResolving`),
    /// in the same space as the resolver's rects (the window's content view):
    /// a pane anchor (tab chip, strip, column edge) stays where it is. Another
    /// window's target, or one that draws nowhere, is `.elsewhere`. So are the
    /// two anchors outside the target's pane (the user, 2026-11-07: "position
    /// of the circle is bad"): `windowEdge`, where nothing in view stands for
    /// the target and the dot sat half clipped on the window's edge, and
    /// `workspaceRow`, where the dot sat over the row's title and the row's
    /// trailing column already shows its status. The titlebar lease indicator
    /// still counts the agent.
    public func placement(forWindow window: String) -> AgentCursorPlacement {
        switch self {
        case .hidden(_, .windowEdge, _), .hidden(_, .workspaceRow, _):
            return .elsewhere
        case let .visible(owner, viewport, clip, zoom, scale) where owner == window:
            // An event's own zoom wins over the page zoom now (agent-cursor.md section 2); the
            // emulation scale (a fit's) applies on top of either.
            return .visible(content: viewport, clip: clip, zoom: zoom, magnification: scale)
        case let .hidden(owner, _, rect) where owner == window:
            return .hidden(anchor: rect)
        default:
            return .elsewhere
        }
    }
}
