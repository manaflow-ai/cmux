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

    /// Seconds at `MotionSpeed.fast`.
    public var baseDuration: TimeInterval {
        switch self {
        case .hover: 0.08
        case .focus: 0.1
        case .fadeIn: 0.12
        case .fadeOut: 0.08
        case .crossfade: 0.1
        case .lift: 0.12
        case .theme: 0.16
        }
    }
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

    public var period: TimeInterval {
        switch self {
        case .spinner: 0.9
        case .pulse: 1.8
        case .flash: 0.6
        }
    }
}
