public import CmuxNextAgentCursor
public import CoreGraphics

extension AgentCursorVisibility {
    /// What the overlay model of `window` draws (`AgentCursorTargetResolving`).
    /// Another window's target, or one that draws nowhere, is `.elsewhere`.
    /// A hidden anchor outside the plane (a sidebar row) moves onto the
    /// plane's nearest edge (`drawableRect`).
    public func placement(forWindow window: String, overlay: CGRect) -> AgentCursorPlacement {
        switch self {
        case let .visible(owner, viewport, clip, zoom) where owner == window:
            // An event's own zoom wins over the page zoom now (agent-cursor.md section 2).
            return .visible(content: viewport, clip: clip, zoom: zoom, magnification: 1)
        case let .hidden(owner, _, rect) where owner == window:
            return .hidden(anchor: AgentCursorVisibilityResolver.drawableRect(rect, in: overlay))
        default:
            return .elsewhere
        }
    }
}
