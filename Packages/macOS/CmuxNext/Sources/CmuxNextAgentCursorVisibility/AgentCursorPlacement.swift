public import CoreGraphics

/// Where an agent's target is in this window right now, in overlay
/// (layout-root, y-down) coordinates. Answered by the layout at the moment an
/// input event arrives, never cached across events: panes, columns and tabs
/// can move between two events. A value of the visibility rules
/// (``AgentCursorVisibility/placement(forWindow:)``), so it lives with them
/// and the cursor (CmuxNextAgentCursor) depends on the rules, not the reverse.
public enum AgentCursorPlacement: Equatable, Sendable {
    /// The target tab is on screen. `content` is its page viewport, `clip`
    /// the part of it not scrolled out or under a docked column, `zoom` the
    /// page zoom now (an event's own `zoom` wins) and `magnification` the
    /// view magnification.
    case visible(content: CGRect, clip: CGRect, zoom: Double, magnification: Double)
    /// The target exists in this window but is not shown (background tab,
    /// column scrolled out of view): point at its tab chip or column edge.
    case hidden(anchor: CGRect)
    /// Not in this window (other workspace, other window, other Space).
    case elsewhere
}
