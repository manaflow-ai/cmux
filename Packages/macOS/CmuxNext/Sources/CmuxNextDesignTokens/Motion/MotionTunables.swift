public import Foundation

/// Debug Settings tunables for every Motion token (plans/cmux-next/motion.md).
/// The literal defaults live here, inside the Motion directory, so
/// `check-motion.sh` still finds no timing constant outside it. Tokens read
/// these, so an override retunes every animation that uses the token, live.
public nonisolated enum MotionTunables {
    // MARK: Springs (speed "fast")

    package static let springDefaults: [MotionSpring: (SpringParameters, String)] = [
        // No spring passes its target (Lawrence 2026-11-10: no bounce in any motion;
        // plans/cmux-next/motion-first-principles-DESIGN.md, principle 5): every damping fraction is 1,
        // critically damped. A token that was under 1 kept its response, so its start is the same and
        // only the pass of the target and the return are gone; its visible end is 1.18 x its response.
        // Every spring ends visibly (within 0.5% of its travel, `SpringParameters.perceivedDuration`)
        // by `MotionScale.ceiling`, 240 ms (Leo 2026-10-20: "animations all around are a bit slow";
        // MotionScaleTests), but `settle`, `popover` and `pinDrag`: their responses were set for a
        // damping under 1 and end later at 1 (MotionScaleTests names them; the response is a Motion
        // Lab choice). Visible ends below are simulated at 480 Hz.
        // The layout springs (design-tokens.json motion.springs): critically damped, as every
        // spring is, response short enough that a move ends visibly (within 0.5%) by 0.18 s (hq-1d D1).
        .move: (SpringParameters(response: 0.15, dampingFraction: 1), "Tab reflow and reorder, sidebar row moves, pane and divider frames."),
        // 0.30 ended visibly at 354 ms; 0.2 ends at 235 ms, under the ceiling (Leo 2026-10-20).
        .zoom: (SpringParameters(response: 0.2, dampingFraction: 1), "A pane zooming to fill its screen and back (Cmd-Shift-Enter)."),
        // 0.24 ended visibly at 283 ms; 0.2 ends at 235 ms, under the ceiling (Leo 2026-10-20).
        .exit: (SpringParameters(response: 0.2, dampingFraction: 1), "A window closing: its fade out (a pane close takes the split spring)."),
        .tabOpen: (SpringParameters(response: 0.1, dampingFraction: 1), "A new tab growing in at its slot and the tabs right of it making room."),
        // plans/cmux-next/split-spring-animation/DESIGN.md. It was 0.95 damped until 2026-11-10 (the
        // numbers that follow were measured then). 0.28 ended visibly at 287 ms (half its travel at
        // 73 ms); 0.23 ended at 235 ms (Leo 2026-10-20). 0.11 ended at 113 ms, 8% of its travel in the
        // first 120 Hz frame and 80% at 50 ms (Leo 2026-11-08: "our animations should be so fast";
        // the instant-splits target is a transition done in 120 ms). 0.11 still moved a pixel at 141 ms
        // on a 696 pt split (its last half point; split-scale bench 133-146 ms from the key), so 0.085:
        // last pixel by about 100 ms at 1x and 108 ms at 2x on 1000 pt, 14% in the first frame, 90% at 50 ms.
        // At damping 1 it ends visibly (within 0.5%) at 101 ms.
        .split: (SpringParameters(response: 0.085, dampingFraction: 1), "Cmd-D and Cmd-Shift-D: the new pane growing in while its whole chain makes room, on one spring."),
        .appear: (SpringParameters(response: 0.135, dampingFraction: 1), "Palette scale-in, tab grow-in, group expand, row insert, sidebar show."),
        .disappear: (SpringParameters(response: 0.11, dampingFraction: 1), "Tab close, group collapse, row removal, sidebar hide."),
        // It carries the pointer's release velocity, as far as the velocity cannot take the item past
        // its place (`SpringParameters.admitted`). At damping 0.85 it ended visibly at 235 ms; at 1 it
        // ends at 260 ms, over the ceiling (a 0.2 response would end at 236 ms: a Motion Lab choice).
        .settle: (SpringParameters(response: 0.22, dampingFraction: 1), "Release after a drag: tab drop, ghost landing, sidebar row drop."),
        // At damping 0.9, 0.22 ended visibly at 190 ms and 0.2 at 173 ms (Leo 2026-10-20); at 1, 0.2
        // ends at 236 ms.
        .scroll: (SpringParameters(response: 0.2, dampingFraction: 1), "Tab strip reveal, strip column reveal, wheel notch, fling snap."),
        .track: (SpringParameters(response: 0.12, dampingFraction: 1), "Drop-zone overlay and the drag ghost jumping between targets."),
        .selection: (SpringParameters(response: 0.15, dampingFraction: 1), "Page info toggle state change. The sidebar selection does not animate."),
        // At damping 0.85, 0.18 ended visibly at 194 ms and 0.165 at 177 ms (Leo 2026-10-20); at 1,
        // 0.165 ends at 195 ms.
        .panel: (SpringParameters(response: 0.165, dampingFraction: 1), "Hover card slide."),
        // Lawrence 2026-10-20 (Home's Chief pill popover, "animation needs to be better"): the card
        // grows out of its control on a spring. Its hint of give (0.86) is gone (no bounce,
        // 2026-11-10). At 0.86, 0.25 ended visibly at 248 ms and 0.24 at 238 ms (Leo 2026-10-20); at
        // 1, 0.24 ends at 284 ms, over the ceiling (a 0.2 response would end at 236 ms).
        .popover: (SpringParameters(response: 0.24, dampingFraction: 1), "A popup growing out of its control (Chief pill, group editors, page info, menus)."),
        // Leaving: 0.16 ended visibly at 188 ms; 0.15 ends at 177 ms, inside standard and still
        // well over the 0.1 s that reads as a cut (Leo 2026-10-20).
        .popoverClose: (SpringParameters(response: 0.15, dampingFraction: 1), "A popup shrinking back toward its control as it fades: faster than its open."),
        // MessagesLab `SidebarPinDragging.spring` (stiffness 320, damping 30: response 0.351, damping
        // fraction 0.84) ended visibly at 390 ms; response 0.215 ended at 238 ms (Leo 2026-10-20). The
        // give is gone (it passed its place by about 1.6 pt on 200 pt): at damping 1, 0.215 ends at
        // 254 ms, over the ceiling (a 0.2 response would end at 236 ms).
        .pinDrag: (SpringParameters(response: 0.215, dampingFraction: 1),
                   "Home list pin drag: tiles making room, rows below the grid, a dropped tile landing."),
    ]

    /// The spring of a token with no entry in `springDefaults` (every token has one today).
    package static let fallbackSpring = SpringParameters(response: 0.2, dampingFraction: 1)

    package static let springs: [MotionSpring: Tunable<SpringParameters>] = Dictionary(uniqueKeysWithValues: MotionSpring.allCases.map { token in
        let entry = springDefaults[token] ?? (fallbackSpring, "")
        return (token, Tunable.spring("motion.spring.\(token.rawValue)", .springs, "\(token.rawValue) spring", help: entry.1,
                                      default: entry.0, code: "MotionTunables.springDefaults[.\(token.rawValue)]"))
    })

    // MARK: Fades and loops

    /// Every timed fade is a `MotionScale` step (or 0, instant), so nothing reads slow (Leo
    /// 2026-10-20: "animations all around are a bit slow"). Off-scale values went to the nearest
    /// step that is not longer. `highlight` and `hibernateRing` are long ambient fades, not
    /// transitions, and stay off the scale (MotionScaleTests lists them).
    package static let fadeDefaults: [MotionFade: (TimeInterval, String)] = [
        .hover: (MotionScale.quick, "Hover and pressed fills easing in, hover-revealed buttons, divider hover."),
        .hoverReveal: (MotionScale.micro, "A group header's + and more fading in and out with the pointer (opacity only)."),
        .hoverOut: (0, "Hover and pressed fills clearing: 0 is instant (as in Edge); about 0.12 leaves a short trail on a sweep."),
        .focus: (MotionScale.quick, "Pane focus ring."),
        .paneDim: (MotionScale.micro, "The dim over an unfocused pane easing in and out when focus moves."),
        .focusFlash: (0.5, "The focus ring flashed on a pane focus moved to without a click, fading out (focus.flashOnMove)."),
        .fadeIn: (MotionScale.micro, "Palette, find bar, notices, hover card appear."),
        .fadeOut: (MotionScale.quick, "Palette close, find bar, notices, hover card hide."),
        .crossfade: (MotionScale.quick, "Hover card thumbnail swap; also the Reduce Motion ceiling of every fade."),
        .scrim: (MotionScale.standard, "Whole-window wash easing in and out (the dim under the palette, an inactive window)."),
        .lift: (MotionScale.micro, "Sidebar drag lift shadow."),
        .theme: (MotionScale.micro, "Room, workspace or terminal theme switch."),
        .highlight: (1.2, "Settings row highlight after a search jump or deep link fades out."),
        .launch: (MotionScale.large, "Launch mark resolving on the glass (scaled by the animation speed; stays under 400 ms)."),
        .clickPulse: (MotionScale.large, "Agent cursor click ripple grows and fades (cmux-cua timing, 250 ms there)."),
        .cursorHide: (MotionScale.large, "Agent cursor fades out once its agent goes idle."),
        .hibernateIcon: (MotionScale.large, "Hibernated tab favicon shrinks into its ring, and grows back on wake (Chrome: 250 ms)."),
        .hibernateRing: (1.0, "Hibernated tab dotted ring fades in (Chrome: 1 s)."),
    ]

    package static let fades: [MotionFade: Tunable<Double>] = Dictionary(uniqueKeysWithValues: MotionFade.allCases.map { token in
        let entry = fadeDefaults[token] ?? (MotionScale.quick, "")
        return (token, Tunable.number("motion.fade.\(token.rawValue)", .fades, "\(token.rawValue) fade", help: entry.1,
                                      default: entry.0, range: 0...(token == .highlight ? 3 : 1), step: 0.01, unit: .seconds,
                                      code: "MotionTunables.fadeDefaults[.\(token.rawValue)]"))
    })

    package static let loopDefaults: [MotionLoop: (TimeInterval, String)] = [
        .spinner: (MotionScale.spinnerPeriod, "One turn of every spinner (schemas/motion-scale/motion-scale.json `spinner`)."),
        .pulse: (1.8, "One cycle of the agent-waiting pulse."),
        .flash: (1, "Pane attention flash (two blinks; at least 1 s, the 2 Hz cap)."),
        .sweep: (1.3, "One pass of an unmeasured progress bar's segment (the update card while checking)."),
        .breath: (2.4, "One breath of the agent-working dot (working look Breathing Dot). Web pages breathe on their own --cmux-breath-period."),
        .wiggle: (0.3, "One back-and-forth of an item's wiggle in the sidebar's edit mode."),
        .nudge: (1, "One bob (up and back) of the arrow in the Computer Use drag panel."),
    ]

    package static let loops: [MotionLoop: Tunable<Double>] = Dictionary(uniqueKeysWithValues: MotionLoop.allCases.map { loop in
        let entry = loopDefaults[loop] ?? (1, "")
        return (loop, Tunable.number("motion.loop.\(loop.rawValue)", .fades, "\(loop.rawValue) period", help: entry.1,
                                     default: entry.0, range: loop.minimumPeriod...4, step: 0.05, unit: .seconds,
                                     code: "MotionTunables.loopDefaults[.\(loop.rawValue)]"))
    })

    // MARK: Marquee and panel scale

    // Not on the motion scale: the marquee delay and hold, the tooltip delay and warm time, the
    // hover card grace and aim, and the launch delays below are hover-intent and wait times, not
    // animations (no transition plays during them), and the marquee scroll is an ambient pass at a
    // reading speed. The panel and popup scales are sizes, not durations.

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

    public static let popupOpenScale = Tunable<Double>.number(
        "motion.popup.openScale", .palette, "Popup open scale", help: "Scale a popup grows from, about its control, when it opens.",
        default: 0.95, range: 0.8...1, step: 0.005, unit: .multiplier, code: "MotionTunables.popupOpenScale")
    public static let popupCloseScale = Tunable<Double>.number(
        "motion.popup.closeScale", .palette, "Popup close scale", help: "Scale a popup shrinks to, toward its control, when it closes.",
        default: 0.97, range: 0.8...1, step: 0.005, unit: .multiplier, code: "MotionTunables.popupCloseScale")

    // MARK: Agent cursor

    /// User, 2026-10-20: the agent cursor's motion is "quick: short, snappy".
    /// A glide keeps the cmux-cua path (speed envelope, then the spring
    /// settle) and plays it in this share of its time, never longer than
    /// ``agentCursorGlideMax``, the motion scale's ceiling (Leo 2026-10-20;
    /// it was 0.28 s).
    public static let agentCursorGlideScale = Tunable<Double>.number(
        "motion.agentCursor.glideScale", .fades, "Agent cursor glide time",
        help: "Share of the cmux-cua glide time an agent cursor glide plays in.",
        default: 0.5, range: 0.1...1, step: 0.05, unit: .multiplier, code: "MotionTunables.agentCursorGlideScale")
    public static let agentCursorGlideMax = Tunable<Double>.number(
        "motion.agentCursor.glideMax", .fades, "Agent cursor glide limit",
        help: "The longest an agent cursor glide plays, however far it goes.",
        default: MotionScale.large, range: 0.05...1, step: 0.01, unit: .seconds, code: "MotionTunables.agentCursorGlideMax")

    // MARK: Launch

    public static let launchMarkDelay = Tunable<Double>.number(
        "motion.launch.markDelay", .fades, "Launch mark delay",
        help: "A launch whose window has content sooner never shows the mark.",
        default: 0.15, range: 0...1, step: 0.01, unit: .seconds, code: "MotionTunables.launchMarkDelay")
    public static let launchTextDelay = Tunable<Double>.number(
        "motion.launch.textDelay", .fades, "Launch status delay",
        help: "How long the mark shows alone before \"Connecting\" appears under it.",
        default: 1.2, range: 0...5, step: 0.05, unit: .seconds, code: "MotionTunables.launchTextDelay")
    package static var launchDelays: [Tunable<Double>] { [launchMarkDelay, launchTextDelay] }

    /// Every Motion tunable, for the catalog.
    public static var all: [TunableDescriptor] {
        MotionSpring.allCases.compactMap { springs[$0]?.descriptor }
            + MotionFade.allCases.compactMap { fades[$0]?.descriptor }
            + MotionLoop.allCases.compactMap { loops[$0]?.descriptor }
            + [marqueeDelay, marqueeSpeed, marqueeMinimumScroll, marqueeHold, marqueeMinimumTravel,
               tooltipDelay, tooltipWarm, hoverCardGrace, hoverCardAim].map(\.descriptor)
            + [panelOpenScale, panelCloseScale, popupOpenScale, popupCloseScale].map(\.descriptor)
            + [agentCursorGlideScale, agentCursorGlideMax].map(\.descriptor)
    }
}

/// Springs as a choice tunable (a variant's animation picks a token).
nonisolated extension MotionSpring: TunableChoice {
    public var tunableTitle: String { rawValue }
}
