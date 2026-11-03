import CCmuxMotionFFI
public import Foundation
public import CmuxNextDesignTokens

/// The hover card state machine (plans/cmux-next/hovercards.md). One per
/// app: there is one phase, so at most one card is pending or shown. The rule
/// is cmux-motion's (`hover::HoverCardMachine`: phases, delays, aiming,
/// bridging, pins, an owner's card), called in process per event through
/// `cmux_hover_card_reduce`; this value keeps the rule's state as the C
/// struct and maps each target id to the 64-bit handle the rule sees. The
/// coordinator feeds it events and runs its effects.
public nonisolated struct HoverCardMachine: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        case idle
        /// The pointer rests on `target`; its card shows when `token` fires.
        case pending(HoverTarget, token: Int)
        /// The card shows `target` because the pointer rests on it.
        case shown(HoverTarget)
        /// The card shows `target` because an action asked for it (Show
        /// Resource Usage). It stays when the pointer leaves; a dismissal or
        /// its lifetime (`token`) ends it.
        case pinned(HoverTarget, token: Int)
        /// The card still shows `target`, but the pointer left every target,
        /// or heads into the card across another one (the safe triangle).
        case leaving(HoverTarget, token: Int)
        /// A card just hid; a hover before `token` fires shows at once.
        case grace(token: Int)
    }

    private var state = CmuxHoverCardMachine()
    /// The 64-bit handle the rule sees for each target id (`HoverCardHandles`).
    private var handles = HoverCardHandles()

    public init(reshowWindow: Duration = HoverCardTiming.reshowWindow, pinLifetime: Duration = HoverCardTiming.pinLifetime,
                leaveWindow: Duration = HoverIntentTiming.standard.cardGrace, aimWindow: Duration = HoverIntentTiming.standard.cardAim,
                stillPointerDelay: Duration = HoverCardTiming.stillPointerDelay) {
        _ = cmux_hover_card_machine_init(&state)
        state.reshow_window = reshowWindow.hoverNanoseconds
        state.pin_lifetime = pinLifetime.hoverNanoseconds
        state.leave_window = leaveWindow.hoverNanoseconds
        state.aim_window = aimWindow.hoverNanoseconds
        state.still_pointer_delay = stillPointerDelay.hoverNanoseconds
    }

    // MARK: State

    /// The rule's phase (`state.phase`: 0 idle, 1 pending, 2 shown, 3 pinned, 4 leaving, 5 grace).
    public var phase: Phase {
        let token = Int(truncatingIfNeeded: state.token)
        let held = handles.target(state.target)
        switch state.phase {
        case 1: return held.map { .pending($0, token: token) } ?? .idle
        case 2: return held.map { .shown($0) } ?? .idle
        case 3: return held.map { .pinned($0, token: token) } ?? .idle
        case 4: return held.map { .leaving($0, token: token) } ?? .idle
        case 5: return .grace(token: token)
        default: return .idle
        }
    }

    /// Active suppressions; no card is pending or shown while any lasts.
    public var suppressions: Set<HoverSuppression> {
        Set(HoverCardHandles.suppressionOrder.enumerated().filter { state.suppressions & (1 << $0.offset) != 0 }.map(\.element))
    }

    /// What the last hit test found under the pointer.
    public var lastHit: HoverTarget? { state.has_last_hit ? handles.target(state.last_hit) : nil }
    /// After a dismissal or suppression, a still pointer starts no card on the target it is
    /// already on; a pointer move clears it.
    public var quiet: Bool { state.quiet }
    /// The next timer token; every token is used once.
    public var nextToken: Int { Int(truncatingIfNeeded: state.next_token) }
    /// The pointer rests on the shown card (the coordinator says so before each deadline).
    public var pointerOnCard: Bool { state.pointer_on_card }
    /// A card its owner shows has the one card window (`HoverCardEvent.owned`).
    public var ownedCardShown: Bool { state.owned_card_shown }

    /// How long after a card hides a new hover shows at once.
    public var reshowWindow: Duration {
        get { Duration(hoverNanoseconds: state.reshow_window) }
        set { state.reshow_window = newValue.hoverNanoseconds }
    }

    /// How long a pinned card stays without a dismissal.
    public var pinLifetime: Duration {
        get { Duration(hoverNanoseconds: state.pin_lifetime) }
        set { state.pin_lifetime = newValue.hoverNanoseconds }
    }

    /// How long a card stays after the pointer leaves every target and the card
    /// (`HoverIntentTiming.cardGrace`).
    public var leaveWindow: Duration {
        get { Duration(hoverNanoseconds: state.leave_window) }
        set { state.leave_window = newValue.hoverNanoseconds }
    }

    /// How long a pointer heading into the shown card may pause on another target it crosses
    /// before that target takes the card over (`HoverIntentTiming.cardAim`).
    public var aimWindow: Duration {
        get { Duration(hoverNanoseconds: state.aim_window) }
        set { state.aim_window = newValue.hoverNanoseconds }
    }

    /// How long a target with no delay waits when it arrives under a still pointer (a scroll,
    /// rows reflowing): only a moving pointer gets the instant card.
    public var stillPointerDelay: Duration {
        get { Duration(hoverNanoseconds: state.still_pointer_delay) }
        set { state.still_pointer_delay = newValue.hoverNanoseconds }
    }

    /// The target whose card is pending or shown.
    public var activeTarget: HoverTarget? {
        switch phase {
        case .pending(let target, _), .shown(let target), .pinned(let target, _), .leaving(let target, _): target
        case .idle, .grace: nil
        }
    }

    /// The target whose card is on screen.
    public var shownTarget: HoverTarget? {
        switch phase {
        case .shown(let target), .pinned(let target, _), .leaving(let target, _): target
        case .idle, .pending, .grace: nil
        }
    }

    /// The token the armed timer carries, if one should be armed.
    public var armedToken: Int? {
        switch phase {
        case .pending(_, let token), .grace(let token), .pinned(_, let token), .leaving(_, let token): token
        case .idle, .shown: nil
        }
    }

    // MARK: Events

    /// Applies one event in the Rust rule and returns what the coordinator does, in order.
    public mutating func reduce(_ event: HoverCardEvent) -> [HoverCardEffect] {
        var raw = handles.cEvent(event)
        var buffer = (CmuxHoverCardEffect(), CmuxHoverCardEffect(), CmuxHoverCardEffect())
        var count = 0
        // One event yields at most 3 effects (cmux-motion `MAX_EFFECTS_PER_EVENT`).
        withUnsafeMutableBytes(of: &buffer) { bytes in
            _ = cmux_hover_card_reduce(&state, &raw, 1, bytes.baseAddress?.assumingMemoryBound(to: CmuxHoverCardEffect.self), 3, &count)
        }
        let effects = handles.effects([buffer.0, buffer.1, buffer.2].prefix(count))
        handles.prune(keeping: state)
        return effects
    }

    // MARK: Hashable (the state as Swift reads it)

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.snapshot == rhs.snapshot }
    public func hash(into hasher: inout Hasher) { hasher.combine(snapshot) }

    private nonisolated struct Snapshot: Hashable {
        var phase: Phase
        var suppressions: Set<HoverSuppression>
        var lastHit: HoverTarget?
        var quiet, pointerOnCard, ownedCardShown, wasOnCard: Bool
        var nextToken: Int
        var windows: [Duration]
    }

    private var snapshot: Snapshot {
        Snapshot(phase: phase, suppressions: suppressions, lastHit: lastHit, quiet: quiet, pointerOnCard: pointerOnCard,
                 ownedCardShown: ownedCardShown, wasOnCard: state.was_on_card, nextToken: nextToken,
                 windows: [reshowWindow, pinLifetime, leaveWindow, aimWindow, stillPointerDelay])
    }
}
