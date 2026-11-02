package import CCmuxMotionFFI
public import Foundation

/// The app's one hover-intent policy (Leo, 2026-10-14: tooltips and hover
/// cards appeared at once everywhere). Tooltips wait before the first one
/// shows, then a neighbor's shows at once while the group is warm; hover
/// cards stay while the pointer heads into them and linger a moment after it
/// leaves. The numbers and their history live in cmux-motion
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
