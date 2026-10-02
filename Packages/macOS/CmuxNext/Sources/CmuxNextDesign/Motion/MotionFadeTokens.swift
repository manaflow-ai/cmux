public import Foundation

/// Timed opacity and color changes (ease-out).
public nonisolated enum MotionFade: String, Sendable, CaseIterable {
    /// Hover fills and hover-revealed buttons.
    case hover
    /// Focus ring and inactive-pane dim.
    case focus
    /// A view or panel fades in.
    case fadeIn
    /// A view, panel or window fades out. Faster than `fadeIn`.
    case fadeOut
    /// Content swap in place (hover card image, reduced-motion replacement).
    case crossfade
    /// Drag lift shadow.
    case lift
    /// A room, workspace or terminal theme switch recoloring in place.
    case theme
    /// A Settings row found by search or a deep link: its highlight fades
    /// out over this long (held this long, then removed, under Reduce Motion).
    case highlight

    /// Seconds at `MotionSpeed.fast` (`MotionTunables`; overridable in
    /// Debug Settings).
    public var baseDuration: TimeInterval { MotionTunables.fades[self]?.value ?? 0.1 }
}

/// Repeating indicators. These show state, so speed does not scale them;
/// `off` and Reduce Motion stop them (the indicator shows a static glyph).
public nonisolated enum MotionLoop: String, Sendable, CaseIterable {
    /// Busy spinner, one turn.
    case spinner
    /// Agent-waiting pulse, one full cycle (dim and back).
    case pulse
    /// Pane attention flash (two blinks).
    case flash

    public var period: TimeInterval { MotionTunables.loops[self]?.value ?? 1 }
}
