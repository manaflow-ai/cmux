public import CmuxNextAgentCursor
public import CoreGraphics

extension AgentCursorVisibility {
    /// What the cursor host of `window` draws (`AgentCursorTargetResolving`),
    /// in the same space as the resolver's rects (the window's content view):
    /// anchors stay where they are, a sidebar row included. Another window's
    /// target, or one that draws nowhere, is `.elsewhere`. So is the
    /// `windowEdge` fallback: nothing in view stands for its target, and its
    /// dot sat half clipped on the window's edge beside an unrelated sidebar
    /// row (the user, 2026-11-07); the titlebar lease indicator still counts it.
    public func placement(forWindow window: String) -> AgentCursorPlacement {
        switch self {
        case .hidden(_, .windowEdge, _):
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
