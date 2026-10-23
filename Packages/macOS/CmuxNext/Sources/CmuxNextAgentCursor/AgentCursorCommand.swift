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
    /// The visible page the session's cursor is in, in overlay coordinates:
    /// its name tag and caption stay inside it (``AgentCursorTagLayout``).
    /// Sent before each place or glide into a visible target.
    case confine(session: String, bounds: CGRect)
    /// Click feedback at the cursor's current point.
    case pulse(session: String)
    /// Show `text` in the keystroke caption beside the cursor (what the
    /// agent types, ``AgentKeystrokeCaption``); it fades when typing stops.
    case caption(session: String, text: String)
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
