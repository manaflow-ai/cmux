package import CCmuxMotionFFI
public import Foundation

/// The app's one hover-intent policy (Leo, 2026-10-14: tooltips and hover
/// cards appeared at once everywhere). Tooltips wait before the first one
/// shows, then a neighbor's shows at once while the group is warm; hover
/// cards wait Chrome's delay (`cardDelay`, below), stay while the pointer heads
/// into them, and linger a moment after it leaves. The native sidebar row and
/// tab cards wait that delay or the user's (`HoverCardTiming`,
/// `sidebar.hoverCards.delay`). The numbers and their history live in cmux-motion
/// (cmux-tui/crates/cmux-motion/src/hover/timing.rs, `HoverIntentTiming::STANDARD`);
/// pages use the same ones (webviews/src/ui/hoverIntent.ts, `HOVER_INTENT`; a web
/// test reads timing.rs and fails when they drift). Each value is a tunable
/// (Debug > Tunables > Hover).
public nonisolated struct HoverIntentTiming: Hashable, Sendable {
    /// Pointer rest before the first tooltip of a group shows.
    public var tooltipDelay: Duration
    /// After the last tooltip hid, how long the next one still shows at once.
    public var tooltipWarm: Duration
    /// How long a card stays after the pointer leaves its target and the card.
    public var cardGrace: Duration
    /// How long a pointer heading for a shown card may pause on another
    /// target it crosses before that target's card takes over.
    public var cardAim: Duration

    public init(tooltipDelay: Duration, tooltipWarm: Duration, cardGrace: Duration, cardAim: Duration) {
        self.tooltipDelay = tooltipDelay
        self.tooltipWarm = tooltipWarm
        self.cardGrace = cardGrace
        self.cardAim = cardAim
    }

    /// Every hover timing token, from cmux-motion (`cmux_hover_timing`), read once.
    package static let rustTable: CmuxHoverTiming = {
        var table = CmuxHoverTiming()
        _ = cmux_hover_timing(&table)
        return table
    }()

    /// The defaults.
    public static let standard = HoverIntentTiming(
        tooltipDelay: Duration(hoverNanoseconds: rustTable.tooltip_delay),
        tooltipWarm: Duration(hoverNanoseconds: rustTable.tooltip_warm),
        cardGrace: Duration(hoverNanoseconds: rustTable.card_grace),
        cardAim: Duration(hoverNanoseconds: rustTable.card_aim))

    /// The values now, with any tunable override.
    public static var current: HoverIntentTiming {
        HoverIntentTiming(
            tooltipDelay: duration(MotionTunables.tooltipDelay.value), tooltipWarm: duration(MotionTunables.tooltipWarm.value),
            cardGrace: duration(MotionTunables.hoverCardGrace.value),
            cardAim: duration(MotionTunables.hoverCardAim.value))
    }

    /// A tunable's seconds: at least zero, rounded to the millisecond (cmux-motion `duration_from_seconds`).
    private static func duration(_ seconds: Double) -> Duration {
        Duration(hoverNanoseconds: cmux_hover_duration_from_seconds(seconds))
    }
}

/// Hover card timing: the one source every hover card in the app reads (sidebar workspace rows,
/// pinned rows, the rail, tabs, group headers and chips, the Update Ready card, Home link chips;
/// the pages' cards read the same numbers from `HOVER_INTENT` in webviews/src/ui/hoverIntent.ts,
/// and webviews/test/hover-intent-parity.test.ts fails when they drift). The values are cmux-motion's
/// (`HOVER_CARD_SHOW_DELAY` and `HOVER_CARD_RESHOW_WINDOW` in cmux-tui/crates/cmux-motion/src/hover/timing.rs),
/// read through `cmux_hover_timing`.
/// webviews/test/hover-card-timing-source.test.ts fails when a hover card source names a delay of its own.
///
/// Chrome's numbers (Lawrence 2026-11-15, msg 32286: "copy chrome's delay exactly, make sure to
/// read chrome's source code ... make sure it is consistent between every thing"), read in
/// Chromium at 6845f5c3ba82 (2026-11-15):
/// - chrome/browser/ui/views/tabs/hovercard/tab_hover_card_controller.cc `GetShowDelay`:
///   `kMinimumTriggerDelay` 300 ms for a tab at pinned width, rising on a log scale to
///   `kMaximumTriggerDelay` 800 ms at standard width, plus `kTabHoverCardAdditionalMaxWidthDelay`
///   (features param, default 500 ms) once a tab is at standard width or wider: 1300 ms. A vertical
///   tab strip scales by the strip's width from `kVerticalTabStripCollapsedWidth` 56 to
///   `kVerticalTabStripDefaultUncollapsedWidth` 240 (chrome/browser/ui/tabs/vertical_tab_strip_state.h),
///   and the horizontal strip uses its widest tab, "so that the delay is consistent for all tabs".
///   Chrome's horizontal tabs are never wider than standard width, so 1300 ms is the longest a tab
///   waits; a default-width vertical strip waits the same. cmux's rows and tabs read as full-width
///   tabs, so every card waits that standard-width value (`cardDelay`), with no width scaling.
/// - `ShouldShowImmediately`: within `kShowWithoutDelayTimeBuffer` 300 ms after the pointer left
///   the last card's target, the next card shows at once (`cardReshow`).
/// - `UpdateOrShowCard`: while a card shows, the next target takes it at once and the card slides
///   over (`kHoverCardSlideDuration` 200 ms, tab_hover_card_bubble_view.h). No delay.
/// - `UpdateHoverCard` with no target: the card hides at once, no grace (`HideHoverCard`; fade-out
///   150 ms, fade-in 200 ms, `views::WidgetFadeAnimator` in ui/views/animation/widget_fade_animator.h).
///   cmux plays its fades and slide on the app's motion scale (`HoverCardMotion`, Leo 2026-10-20).
/// There is no rest-detection shortcut: a pointer that stops on a target still waits the whole delay.
public nonisolated extension HoverIntentTiming {
    /// The cold wait before the first hover card opens: Chrome's delay for a standard-width tab.
    static let cardDelay = Duration(hoverNanoseconds: rustTable.card_show_delay)
    /// After a card went, a hover this soon shows the next card at once (Chrome's
    /// `kShowWithoutDelayTimeBuffer`).
    static let cardReshow = Duration(hoverNanoseconds: rustTable.card_reshow_window)

    /// Chrome's `GetShowDelay` for a target `width` wide where `minWidth` is a pinned tab (or a
    /// collapsed vertical strip) and `standardWidth` a standard tab (or a default-width strip).
    /// At `standardWidth` it gives `cardDelay`; past it (only a vertical strip gets wider) the log
    /// keeps rising slowly. cmux does not scale by width; this documents and tests the source.
    static func chromeShowDelay(width: Double, minWidth: Double, standardWidth: Double) -> Duration {
        let minimum = 300.0, maximum = 800.0, additionalAtStandardWidth = 500.0
        guard width > minWidth else { return .milliseconds(Int(minimum)) }
        let fraction = log(width - minWidth + 1) / log(standardWidth - minWidth + 1)
        var ms = fraction * (maximum - minimum) + minimum
        if width >= standardWidth { ms += additionalAtStandardWidth }
        return .milliseconds(Int(ms.rounded()))
    }
}

/// Hover intent for one warm group of tooltips: a target under the pointer
/// shows after `delay`, or at once while the group is warm (a tooltip shows,
/// or hid less than `warmFor` ago). Moving to another target before the
/// delay restarts it, so a sweep shows nothing. The rule is cmux-motion's
/// (`hover::HoverIntent`, through `cmux_hover_intent_call`); this value keeps
/// its state and maps each target to the 64-bit handle the rule sees. Its
/// owner feeds it the target under the pointer and timer deadlines, and runs
/// the effects on its one timer.
public nonisolated struct HoverIntent<Target: Hashable & Sendable>: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        case idle
        /// The pointer rests on `target`; it shows when `token` fires.
        case pending(Target, token: Int)
        case shown(Target)
        /// Nothing shows; until `token` fires, the next target shows at once.
        case warm(token: Int)
    }

    public enum Effect: Hashable, Sendable {
        /// Arm the one timer for `token`, replacing any armed one.
        case schedule(token: Int, after: Duration)
        case cancelTimer
        case show(Target)
        case hide
    }

    private var state = CmuxHoverIntent()
    /// The 64-bit handle the rule sees for each target (`HoverIntentHandles`).
    private var handles = HoverIntentHandles<Target>()

    public var delay: Duration {
        get { Duration(hoverNanoseconds: state.delay) }
        set { state.delay = newValue.hoverNanoseconds }
    }

    public var warmFor: Duration {
        get { Duration(hoverNanoseconds: state.warm_for) }
        set { state.warm_for = newValue.hoverNanoseconds }
    }

    public init(delay: Duration, warmFor: Duration) {
        _ = cmux_hover_intent_init(delay.hoverNanoseconds, warmFor.hoverNanoseconds, &state)
    }

    /// The phase as the rule holds it (`state.phase`: 0 idle, 1 pending, 2 shown, 3 warm).
    public var phase: Phase {
        let token = Int(truncatingIfNeeded: state.token)
        switch state.phase {
        case 1: return handles.target(state.target).map { .pending($0, token: token) } ?? .idle
        case 2: return handles.target(state.target).map { .shown($0) } ?? .idle
        case 3: return .warm(token: token)
        default: return .idle
        }
    }

    public var shown: Target? {
        if case .shown(let target) = phase { return target }
        return nil
    }

    public var isWarm: Bool { state.phase == 2 || state.phase == 3 }

    /// The target under the pointer now (nil: none).
    public mutating func hover(_ target: Target?) -> [Effect] {
        var raw: UInt64?
        if let target { raw = handles.handle(target) }
        return call(0, target: raw, value: 0)
    }

    public mutating func deadline(_ token: Int) -> [Effect] {
        call(1, target: nil, value: UInt64(truncatingIfNeeded: token))
    }

    /// A click, a key or a scroll: whatever shows goes, and the group is cold again.
    public mutating func dismiss() -> [Effect] {
        call(2, target: nil, value: 0)
    }

    private mutating func call(_ call: UInt8, target: UInt64?, value: UInt64) -> [Effect] {
        var raw = (CmuxHoverIntentEffect(), CmuxHoverIntentEffect())
        let count = withUnsafeMutableBytes(of: &raw) { bytes in
            cmux_hover_intent_call(&state, call, target != nil, target ?? value,
                                   bytes.baseAddress?.assumingMemoryBound(to: CmuxHoverIntentEffect.self), 2)
        }
        let effects = handles.effects([raw.0, raw.1].prefix(count))
        handles.prune(keeping: state)
        return effects
    }

    // MARK: Hashable (the state as Swift reads it; the C struct has no conformance)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.phase == rhs.phase && lhs.state.next_token == rhs.state.next_token && lhs.delay == rhs.delay && lhs.warmFor == rhs.warmFor
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(phase)
        hasher.combine(state.next_token)
        hasher.combine(delay)
        hasher.combine(warmFor)
    }
}

/// The safe triangle (Amazon's menu aim, macOS submenus).
nonisolated extension CGRect {
    /// Whether a pointer moving from `from` to `to` heads for this rect (a
    /// shown card): `to` lies in it, or the move heads for it and `to` lies in
    /// the triangle from `from` to its nearer edge (cmux-motion
    /// `HoverRect::aimed_at`). A target it crosses on the way then does not
    /// take the card over. Screen coordinates; webviews/src/ui/hoverIntent.ts
    /// (`aimingAt`, for submenus) has the triangle without the heading test.
    public func isAimedAt(from: CGPoint?, to: CGPoint?) -> Bool {
        cmux_hover_is_aimed_at(CmuxHoverRect(self), from != nil, CmuxHoverPoint(from ?? .zero),
                               to != nil, CmuxHoverPoint(to ?? .zero))
    }
}
