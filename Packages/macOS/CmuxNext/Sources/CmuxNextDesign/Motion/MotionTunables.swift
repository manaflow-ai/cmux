public import Foundation

/// Debug Settings tunables for every Motion token (plans/cmux-next/motion.md).
/// The literal defaults live here, inside the Motion directory, so
/// `check-motion.sh` still finds no timing constant outside it. Tokens read
/// these, so an override retunes every animation that uses the token, live.
public nonisolated enum MotionTunables {
    // MARK: Springs (speed "fast")

    static let springDefaults: [MotionSpring: (SpringParameters, String)] = [
        .move: (SpringParameters(response: 0.2, dampingFraction: 0.9), "Tab reflow and reorder, sidebar row moves, pane and divider frames."),
        .appear: (SpringParameters(response: 0.18, dampingFraction: 0.9), "Palette scale-in, tab grow-in, group expand, row insert, sidebar show."),
        .disappear: (SpringParameters(response: 0.15, dampingFraction: 0.9), "Tab close, group collapse, row removal, sidebar hide."),
        .settle: (SpringParameters(response: 0.22, dampingFraction: 0.85), "Release after a drag: tab drop, ghost landing, sidebar row drop."),
        .scroll: (SpringParameters(response: 0.22, dampingFraction: 0.9), "Tab strip reveal, strip column reveal, wheel notch, fling snap."),
        .screen: (SpringParameters(response: 0.22, dampingFraction: 0.9), "Screen switch slide."),
        .track: (SpringParameters(response: 0.12, dampingFraction: 0.9), "Drop-zone overlay and the drag ghost jumping between targets."),
        .selection: (SpringParameters(response: 0.15, dampingFraction: 0.9), "Sidebar selection pill."),
        .panel: (SpringParameters(response: 0.18, dampingFraction: 0.85), "Hover card slide."),
    ]

    static let springs: [MotionSpring: Tunable<SpringParameters>] = Dictionary(uniqueKeysWithValues: MotionSpring.allCases.map { token in
        let entry = springDefaults[token] ?? (SpringParameters(response: 0.2, dampingFraction: 0.9), "")
        return (token, Tunable.spring("motion.spring.\(token.rawValue)", .springs, "\(token.rawValue) spring", help: entry.1,
                                      default: entry.0, code: "MotionTunables.springDefaults[.\(token.rawValue)]"))
    })

    // MARK: Fades and loops

    static let fadeDefaults: [MotionFade: (TimeInterval, String)] = [
        .hover: (0.08, "Hover fills, hover-revealed buttons, divider hover."),
        .focus: (0.1, "Pane focus ring and inactive dim."),
        .fadeIn: (0.12, "Palette, find bar, notices, hover card appear."),
        .fadeOut: (0.08, "Palette close, find bar, notices, hover card hide."),
        .crossfade: (0.1, "Hover card thumbnail swap; also the Reduce Motion ceiling."),
        .lift: (0.12, "Sidebar drag lift shadow."),
        .theme: (0.16, "Room, workspace or terminal theme switch."),
        .highlight: (1.2, "Settings row highlight after a search jump or deep link fades out."),
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
        .flash: (0.6, "Pane attention flash (two blinks)."),
    ]

    static let loops: [MotionLoop: Tunable<Double>] = Dictionary(uniqueKeysWithValues: MotionLoop.allCases.map { loop in
        let entry = loopDefaults[loop] ?? (1, "")
        return (loop, Tunable.number("motion.loop.\(loop.rawValue)", .fades, "\(loop.rawValue) period", help: entry.1,
                                     default: entry.0, range: 0.1...4, step: 0.05, unit: .seconds, code: "MotionTunables.loopDefaults[.\(loop.rawValue)]"))
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
    public static let panelOpenScale = Tunable<Double>.number(
        "motion.panel.openScale", .palette, "Panel open scale", help: "Scale the palette grows from when it opens.",
        default: 0.97, range: 0.8...1, step: 0.005, unit: .multiplier, code: "MotionTunables.panelOpenScale")
    public static let panelCloseScale = Tunable<Double>.number(
        "motion.panel.closeScale", .palette, "Panel close scale", help: "Scale the palette shrinks to when it closes.",
        default: 0.98, range: 0.8...1, step: 0.005, unit: .multiplier, code: "MotionTunables.panelCloseScale")

    /// Every Motion tunable, for the catalog.
    public static var all: [TunableDescriptor] {
        MotionSpring.allCases.compactMap { springs[$0]?.descriptor }
            + MotionFade.allCases.compactMap { fades[$0]?.descriptor }
            + MotionLoop.allCases.compactMap { loops[$0]?.descriptor }
            + [marqueeDelay, marqueeSpeed, marqueeMinimumScroll, marqueeHold, marqueeMinimumTravel].map(\.descriptor)
            + [panelOpenScale, panelCloseScale].map(\.descriptor)
    }
}

/// Springs as a choice tunable (a variant's animation picks a token).
nonisolated extension MotionSpring: TunableChoice {
    public var tunableTitle: String { rawValue }
}
