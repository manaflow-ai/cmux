public import CoreGraphics

/// Where an agent's target is in this window right now, in overlay
/// (layout-root, y-down) coordinates. Answered by the layout at the moment an
/// input event arrives, never cached across events: panes, columns and tabs
/// can move between two events.
public enum AgentCursorPlacement: Equatable, Sendable {
    /// The target tab is on screen. `content` is its page content rect;
    /// `magnification` is the view magnification (page zoom comes with the
    /// event).
    case visible(content: CGRect, magnification: Double)
    /// The target exists in this window but is not shown (background tab,
    /// column scrolled out of view): point at its tab chip or column edge.
    case hidden(anchor: CGRect)
    /// Not in this window (other workspace, other window, other Space).
    case elsewhere
}

/// Answers where a target is. The stand-in for the visibility resolver
/// (owner a9: a pure resolver with vectors); the App supplies the live one.
@MainActor
public protocol AgentCursorTargetResolving: AnyObject {
    func placement(forTarget targetID: String) -> AgentCursorPlacement
}
