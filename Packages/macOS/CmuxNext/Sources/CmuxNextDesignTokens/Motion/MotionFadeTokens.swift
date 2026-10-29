public import Foundation

/// Timed opacity and color changes (ease-out).
public nonisolated enum MotionFade: String, Sendable, CaseIterable {
    /// Hover and pressed fills easing in, and hover-revealed buttons.
    case hover
    /// A group header's hover buttons (+ and more) fading in and out with the
    /// pointer (Lawrence 2026-10-19, u2397): opacity only, ease-out. Instant
    /// under Reduce Motion, as both hover tokens are.
    case hoverReveal
    /// Hover and pressed fills clearing (`ChromeHover.fade(to:)`). 0, so
    /// instant, by default, as in Edge: a fast sweep down a list leaves no
    /// trail. Under Reduce Motion both hover tokens are instant.
    case hoverOut
    /// Focus ring.
    case focus
    /// The veil over an unfocused pane easing in and out when focus moves (Leo 2026-10-21: a short
    /// ease, not a jump; `MotionScale.micro` since Leo 2026-10-20's shorter scale).
    case paneDim
    /// The focus ring shown at once on a pane focus moved to without a click, fading out
    /// (`focus.flashOnMove`, a Debug toggle). Instant, so nothing shows, with no animation.
    case focusFlash
    /// A view or panel fades in.
    case fadeIn
    /// A view, panel or window fades out. Faster than `fadeIn`.
    case fadeOut
    /// Content swap in place (hover card image, reduced-motion replacement). Also the Reduce
    /// Motion ceiling of every fade (`MotionPolicy.duration`): `MotionScale.quick`.
    case crossfade
    /// A wash over a whole window easing in and out: the inactive-window
    /// tint that darkens the window under the palette (Leo 2026-10-20: shown
    /// in one frame it was too jarring). Reduce Motion caps it at `crossfade`.
    case scrim
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
    /// back when the tab wakes (Chromium `TabIcon` favicon size animation,
    /// 250 ms; here the motion scale's ceiling, 240 ms).
    case hibernateIcon
    /// A hibernated tab's dotted ring fading in (Chromium `TabIcon` discard
    /// animation, 1 s). Reduce Motion caps it at one crossfade.
    case hibernateRing

    /// Seconds at `MotionSpeed.fast` (`MotionTunables`; overridable in
    /// Debug Settings).
    public var baseDuration: TimeInterval { MotionTunables.fades[self]?.value ?? MotionScale.quick }
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
    /// Unmeasured progress: a segment crosses its track once.
    case sweep
    /// Agent work's dot, one breath (bright, dim and back; `StatusWorkingLook.breathe`).
    case breath
    /// Edit mode's wiggle (the sidebar's items, as an iPhone's home screen): one turn either way and back.
    case wiggle
    /// A pointing arrow's bob (the Computer Use drag panel's arrow up to the list): up and back down.
    case nudge

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
        case .sweep: Self.shortestFlashCycle
        // A breath is calm: never quicker than one a second.
        case .breath: Self.shortestFlashCycle * 2
        case .wiggle: 0.1
        // A bob moves, it does not flash; it stays slow enough to read as calm.
        case .nudge: Self.shortestFlashCycle
        }
    }
}
