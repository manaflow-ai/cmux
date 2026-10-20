public import Foundation

/// Timed opacity and color changes (ease-out).
public nonisolated enum MotionFade: String, Sendable, CaseIterable {
    /// Hover and pressed fills easing in, and hover-revealed buttons.
    case hover
    /// Hover and pressed fills clearing (`ChromeHover.fade(to:)`). 0, so
    /// instant, by default, as in Edge: a fast sweep down a list leaves no
    /// trail. Under Reduce Motion both hover tokens are instant.
    case hoverOut
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
    /// The launch mark resolving on the window glass (`LaunchMarkView`).
    case launch
    /// An agent cursor's click ripple grows and fades (cmux-cua timing).
    case clickPulse
    /// An agent cursor fades out once its agent goes idle (agent-cursor.md).
    case cursorHide
    /// A hibernated tab's favicon shrinking into its dotted ring, and growing
    /// back when the tab wakes (Chromium `TabIcon` favicon size animation, 250 ms).
    case hibernateIcon
    /// A hibernated tab's dotted ring fading in (Chromium `TabIcon` discard
    /// animation, 1 s). Reduce Motion caps it at one crossfade.
    case hibernateRing

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

    /// Seconds per period, never under `minimumPeriod` (a Debug Settings
    /// override included).
    public var period: TimeInterval { max(MotionTunables.loops[self]?.value ?? 1, minimumPeriod) }

    /// The 2 Hz cap (cx-sya4n: blinking lights give headaches): nothing
    /// flashes faster than twice a second, so every on-off-on cycle of an
    /// opacity loop lasts at least `shortestFlashCycle`. A pulse is one cycle
    /// per period, a flash two blinks per period; a spinner turns and does
    /// not flash.
    public static let shortestFlashCycle: TimeInterval = 0.5

    /// The shortest period `loop` may take.
    public var minimumPeriod: TimeInterval {
        switch self {
        case .spinner: 0.1
        case .pulse: Self.shortestFlashCycle
        case .flash: Self.shortestFlashCycle * 2
        }
    }
}
