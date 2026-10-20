public import Foundation

/// Debug Settings tunables for every Motion token (plans/cmux-next/motion.md).
/// The literal defaults live here, inside the Motion directory, so
/// `check-motion.sh` still finds no timing constant outside it. Tokens read
/// these, so an override retunes every animation that uses the token, live.
public nonisolated enum MotionTunables {
    // MARK: Springs (speed "fast")

    static let springDefaults: [MotionSpring: (SpringParameters, String)] = [
        // Structural (design-tokens.json motion.springs, motion.structural): critically damped by
        // default, response short enough that a move ends visibly (within 0.5%) by 0.18 s (hq-1d D1).
        .move: (SpringParameters(response: 0.15, dampingFraction: 1), "Tab reflow and reorder, sidebar row moves, pane and divider frames."),
        .zoom: (SpringParameters(response: 0.30, dampingFraction: 1), "A pane zooming to fill its screen and back (Cmd-Shift-Enter)."),
        .exit: (SpringParameters(response: 0.24, dampingFraction: 1), "A window closing: its fade out (a pane close takes the split spring)."),
        .tabOpen: (SpringParameters(response: 0.1, dampingFraction: 1), "A new tab growing in at its slot and the tabs right of it making room."),
        // plans/cmux-next/split-spring-animation/DESIGN.md: half its travel at ~73 ms (the key reads as
        // answered), a 700 pt split visibly at rest by ~375 ms, overshoot under 0.1 pt.
        .split: (SpringParameters(response: 0.28, dampingFraction: 0.95), "Cmd-D and Cmd-Shift-D: the new pane growing in while its whole chain makes room, on one spring."),
        .appear: (SpringParameters(response: 0.135, dampingFraction: 1), "Palette scale-in, tab grow-in, group expand, row insert, sidebar show."),
        .disappear: (SpringParameters(response: 0.11, dampingFraction: 1), "Tab close, group collapse, row removal, sidebar hide."),
        .settle: (SpringParameters(response: 0.22, dampingFraction: 0.85), "Release after a drag: tab drop, ghost landing, sidebar row drop."),
        .scroll: (SpringParameters(response: 0.22, dampingFraction: 0.9), "Tab strip reveal, strip column reveal, wheel notch, fling snap."),
        .screen: (SpringParameters(response: 0.22, dampingFraction: 0.9), "Screen switch slide."),
        .track: (SpringParameters(response: 0.12, dampingFraction: 0.9), "Drop-zone overlay and the drag ghost jumping between targets."),
        .selection: (SpringParameters(response: 0.15, dampingFraction: 0.9), "Page info toggle state change. The sidebar selection does not animate."),
        .panel: (SpringParameters(response: 0.18, dampingFraction: 0.85), "Hover card slide."),
        .pinDrag: (SpringParameters(response: 0.3512407365520363, dampingFraction: 0.8385254915624211),
                   "Home list pin drag: tiles making room, rows below the grid, a dropped tile landing."),
    ]

    static let springs: [MotionSpring: Tunable<SpringParameters>] = Dictionary(uniqueKeysWithValues: MotionSpring.allCases.map { token in
        let entry = springDefaults[token] ?? (SpringParameters(response: 0.2, dampingFraction: 0.9), "")
        return (token, Tunable.spring("motion.spring.\(token.rawValue)", .springs, "\(token.rawValue) spring", help: entry.1,
                                      default: entry.0, code: "MotionTunables.springDefaults[.\(token.rawValue)]"))
    })

    /// SwiftUI bounce of the structural springs (`move`, `appear`,
    /// `disappear`) when `ui.animations.bounce` is "subtle". With "none"
    /// (the default) they are critically damped and never pass the target.
    public static let subtleBounce = Tunable<Double>.number(
        "motion.spring.subtleBounce", .springs, "Subtle bounce",
        help: "Bounce of tab, row, pane and divider springs when Animations Bounce is Subtle (0 is critically damped).",
        default: 0.15, range: 0...0.5, step: 0.01, unit: .multiplier, code: "MotionTunables.subtleBounce")

    /// How far ahead a released divider's velocity is projected to find a
    /// snap (halves, thirds) it is flung onto; it then springs there from
    /// that velocity.
    public static let dividerReleaseProjection = Tunable<Double>.number(
        "motion.divider.releaseProjection", .springs, "Divider fling projection",
        help: "Seconds of release velocity a divider looks ahead for a snap point.",
        default: 0.05, range: 0...0.3, step: 0.01, unit: .seconds, code: "MotionTunables.dividerReleaseProjection")

    // MARK: Fades and loops

    static let fadeDefaults: [MotionFade: (TimeInterval, String)] = [
        .hover: (0.08, "Hover and pressed fills easing in, hover-revealed buttons, divider hover."),
        .hoverOut: (0, "Hover and pressed fills clearing: 0 is instant (as in Edge); about 0.12 leaves a short trail on a sweep."),
        .focus: (0.1, "Pane focus ring and inactive dim."),
        .fadeIn: (0.12, "Palette, find bar, notices, hover card appear."),
        .fadeOut: (0.08, "Palette close, find bar, notices, hover card hide."),
        .crossfade: (0.1, "Hover card thumbnail swap; also the Reduce Motion ceiling."),
        .lift: (0.12, "Sidebar drag lift shadow."),
        .theme: (0.16, "Room, workspace or terminal theme switch."),
        .highlight: (1.2, "Settings row highlight after a search jump or deep link fades out."),
        .launch: (0.24, "Launch mark resolving on the glass (scaled by the animation speed; stays under 400 ms)."),
        .clickPulse: (0.25, "Agent cursor click ripple grows and fades (cmux-cua timing)."),
        .cursorHide: (0.3, "Agent cursor fades out once its agent goes idle."),
        .hibernateIcon: (0.25, "Hibernated tab favicon shrinks into its ring, and grows back on wake (Chrome: 250 ms)."),
        .hibernateRing: (1.0, "Hibernated tab dotted ring fades in (Chrome: 1 s)."),
    ]

    static let fades: [MotionFade: Tunable<Double>] = Dictionary(uniqueKeysWithValues: MotionFade.allCases.map { token in
        let entry = fadeDefaults[token] ?? (0.1, "")
        return (token, Tunable.number("motion.fade.\(token.rawValue)", .fades, "\(token.rawValue) fade", help: entry.1,
                                      default: entry.0, range: 0...(token == .highlight ? 3 : 1), step: 0.01, unit: .seconds,
                                      code: "MotionTunables.fadeDefaults[.\(token.rawValue)]"))
    })

    static let loopDefaults: [MotionLoop: (TimeInterval, String)] = [
        .spinner: (0.9, "One turn of the busy spinner."),
        .pulse: (1.8, "One cycle of the agent-waiting pulse."),
        .flash: (1, "Pane attention flash (two blinks; at least 1 s, the 2 Hz cap)."),
    ]

    static let loops: [MotionLoop: Tunable<Double>] = Dictionary(uniqueKeysWithValues: MotionLoop.allCases.map { loop in
        let entry = loopDefaults[loop] ?? (1, "")
        return (loop, Tunable.number("motion.loop.\(loop.rawValue)", .fades, "\(loop.rawValue) period", help: entry.1,
                                     default: entry.0, range: loop.minimumPeriod...4, step: 0.05, unit: .seconds,
                                     code: "MotionTunables.loopDefaults[.\(loop.rawValue)]"))
    })

    // MARK: Marquee and panel scale

    public static let marqueeDelay = Tunable<Double>.number(
        "motion.marquee.delay", .hover, "Marquee delay", help: "Pointer rest before a clipped title starts to scroll.",
        default: 0.6, range: 0...3, step: 0.05, unit: .seconds, code: "MotionTunables.marqueeDelay")
    public static let marqueeSpeed = Tunable<Double>.number(
        "motion.marquee.speed", .hover, "Marquee speed", help: "Scroll speed of a clipped title.",
        default: 40, range: 5...200, step: 1, unit: .pointsPerSecond, code: "MotionTunables.marqueeSpeed")
    public static let marqueeMinimumScroll = Tunable<Double>.number(
        "motion.marquee.minimumScroll", .hover, "Marquee shortest scroll", help: "A few clipped points still take this long.",
        default: 0.4, range: 0...2, step: 0.05, unit: .seconds, code: "MotionTunables.marqueeMinimumScroll")
    public static let marqueeHold = Tunable<Double>.number(
        "motion.marquee.hold", .hover, "Marquee hold", help: "Pause at the end of the title before it scrolls back.",
        default: 1.2, range: 0...5, step: 0.05, unit: .seconds, code: "MotionTunables.marqueeHold")
    public static let marqueeMinimumTravel = Tunable<Double>.number(
        "motion.marquee.minimumTravel", .hover, "Marquee minimum travel", help: "Clipping under this many points never scrolls.",
        default: 2, range: 0...40, step: 1, unit: .points, code: "MotionTunables.marqueeMinimumTravel")
    /// Leo 2026-10-14: hover intent app-wide (`HoverIntentTiming`, AppKit's
    /// `NSInitialToolTipDelay` is about 1 s).
    public static let tooltipDelay = Tunable<Double>.number(
        "motion.tooltip.delay", .hover, "Tooltip delay", help: "Pointer rest before the first tooltip shows.",
        default: 0.45, range: 0...3, step: 0.05, unit: .seconds, code: "MotionTunables.tooltipDelay")
    public static let tooltipWarm = Tunable<Double>.number(
        "motion.tooltip.warm", .hover, "Tooltip warm time", help: "After a tooltip hides, how long the next one shows at once.",
        default: 0.5, range: 0...3, step: 0.05, unit: .seconds, code: "MotionTunables.tooltipWarm")
    public static let hoverCardGrace = Tunable<Double>.number(
        "motion.hoverCard.grace", .hover, "Hover card grace", help: "How long a hover card stays after the pointer leaves its row and the card.",
        default: 0.2, range: 0...2, step: 0.05, unit: .seconds, code: "MotionTunables.hoverCardGrace")
    public static let hoverCardAim = Tunable<Double>.number(
        "motion.hoverCard.aim", .hover, "Hover card aim", help: "How long a pointer heading into a hover card may pause on a row it crosses.",
        default: 0.3, range: 0...2, step: 0.05, unit: .seconds, code: "MotionTunables.hoverCardAim")
    public static let panelOpenScale = Tunable<Double>.number(
        "motion.panel.openScale", .palette, "Panel open scale", help: "Scale the palette grows from when it opens.",
        default: 0.97, range: 0.8...1, step: 0.005, unit: .multiplier, code: "MotionTunables.panelOpenScale")
    public static let panelCloseScale = Tunable<Double>.number(
        "motion.panel.closeScale", .palette, "Panel close scale", help: "Scale the palette shrinks to when it closes.",
        default: 0.98, range: 0.8...1, step: 0.005, unit: .multiplier, code: "MotionTunables.panelCloseScale")

    // MARK: Launch

    public static let launchMarkDelay = Tunable<Double>.number(
        "motion.launch.markDelay", .fades, "Launch mark delay",
        help: "A launch whose window has content sooner never shows the mark.",
        default: 0.15, range: 0...1, step: 0.01, unit: .seconds, code: "MotionTunables.launchMarkDelay")
    public static let launchTextDelay = Tunable<Double>.number(
        "motion.launch.textDelay", .fades, "Launch status delay",
        help: "How long the mark shows alone before \"Connecting\" appears under it.",
        default: 1.2, range: 0...5, step: 0.05, unit: .seconds, code: "MotionTunables.launchTextDelay")
    static var launchDelays: [Tunable<Double>] { [launchMarkDelay, launchTextDelay] }

    /// Every Motion tunable, for the catalog.
    public static var all: [TunableDescriptor] {
        MotionSpring.allCases.compactMap { springs[$0]?.descriptor } + [subtleBounce.descriptor, dividerReleaseProjection.descriptor]
            + MotionFade.allCases.compactMap { fades[$0]?.descriptor }
            + MotionLoop.allCases.compactMap { loops[$0]?.descriptor }
            + [marqueeDelay, marqueeSpeed, marqueeMinimumScroll, marqueeHold, marqueeMinimumTravel,
               tooltipDelay, tooltipWarm, hoverCardGrace, hoverCardAim].map(\.descriptor)
            + [panelOpenScale, panelCloseScale].map(\.descriptor)
    }
}

/// Springs as a choice tunable (a variant's animation picks a token).
nonisolated extension MotionSpring: TunableChoice {
    public var tunableTitle: String { rawValue }
}
