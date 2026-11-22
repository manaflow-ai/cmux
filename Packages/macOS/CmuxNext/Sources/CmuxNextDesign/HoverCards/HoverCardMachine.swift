public import Foundation

/// The hover card state machine (plans/cmux-next/hovercards.md). One per
/// app: there is one phase, so at most one card is pending or shown.
/// Pure: the coordinator feeds it events and runs its effects.
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
        /// The card still shows `target`, but the pointer left every target;
        /// another target before `token` fires slides the card over (no fade
        /// gap crossing a header or a gap between rows), else it hides.
        case leaving(HoverTarget, token: Int)
        /// A card just hid; a hover before `token` fires shows at once
        /// (quick reshow).
        case grace(token: Int)
    }

    public private(set) var phase: Phase = .idle
    /// Active suppressions; no card is pending or shown while any lasts.
    public private(set) var suppressions: Set<HoverSuppression> = []
    /// What the last hit test found under the pointer.
    public private(set) var lastHit: HoverTarget?
    /// After a dismissal or suppression, a still pointer starts no card on
    /// the target it is already on; a pointer move clears it.
    public private(set) var quiet = false
    /// The next timer token; every token is used once.
    public private(set) var nextToken = 1
    /// How long after a card hides a new hover shows at once.
    public var reshowWindow: Duration
    /// How long a pinned card stays without a dismissal.
    public var pinLifetime: Duration
    /// How long a card stays after the pointer leaves every target.
    public var leaveWindow: Duration
    /// How long a target with no delay waits when it arrives under a still
    /// pointer (a scroll, rows reflowing): only a moving pointer gets the
    /// instant card, so content passing under it flashes none.
    public var stillPointerDelay: Duration

    public init(reshowWindow: Duration = .milliseconds(700), pinLifetime: Duration = .seconds(10),
                leaveWindow: Duration = .milliseconds(150), stillPointerDelay: Duration = .milliseconds(300)) {
        self.reshowWindow = reshowWindow
        self.pinLifetime = pinLifetime
        self.leaveWindow = leaveWindow
        self.stillPointerDelay = stillPointerDelay
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

    public mutating func reduce(_ event: HoverCardEvent) -> [HoverCardEffect] {
        switch event {
        case .hit(let target, let moved):
            return hit(target, moved: moved)
        case .deadline(let token):
            switch phase {
            case .pending(let target, let armed) where armed == token:
                phase = .shown(target)
                return [.show(target, sliding: false)]
            case .grace(let armed) where armed == token:
                phase = .idle
                return []
            case .leaving(_, let armed) where armed == token:
                // No target took the card over: it hides, and a quick
                // return still shows at once.
                let grace = takeToken()
                phase = .grace(token: grace)
                return [.hide, .schedule(token: grace, after: reshowWindow)]
            case .pinned(let target, let armed) where armed == token:
                // The pinned card's lifetime ended (its timer is spent). With
                // the pointer still on its target it stays as a hover card.
                if suppressions.isEmpty, lastHit?.id == target.id {
                    phase = .shown(lastHit ?? target)
                    return []
                }
                phase = .idle
                return [.hide] + resume()
            default:
                // A stale token (its state was left before it fired) does nothing.
                return []
            }
        case .dismiss:
            quiet = true
            return end()
        case .suppress(let reason):
            suppressions.insert(reason)
            quiet = true
            return end()
        case .unsuppress(let reason):
            suppressions.remove(reason)
            // A pointer that moved during the drag or scroll gets its card.
            return resume()
        case .targetRemoved(let id):
            if lastHit?.id == id { lastHit = nil }
            guard activeTarget?.id == id else { return [] }
            return end() + resume()
        case .pin(let target):
            // No card during a drag or scroll, pinned or not.
            guard suppressions.isEmpty else { return [] }
            quiet = false
            let wasShown = shownTarget != nil
            let token = takeToken()
            phase = .pinned(target, token: token)
            return [.schedule(token: token, after: pinLifetime), .show(target, sliding: wasShown)]
        }
    }

    private mutating func hit(_ target: HoverTarget?, moved: Bool) -> [HoverCardEffect] {
        let previous = lastHit
        lastHit = target
        // Quiet covers only the target the pointer already rested on: a
        // pointer move, or another target arriving under it, ends it.
        if moved || target?.id != previous?.id { quiet = false }
        if !suppressions.isEmpty {
            return phase == .idle ? [] : end()
        }
        // A still pointer after a dismissal starts nothing on the target it
        // was already on; a different target moving under it may.
        if quiet, !moved, target?.id == previous?.id {
            if let shown = shownTarget, shown.id == target?.id { return [] }
            return phase == .idle ? [] : end()
        }
        switch phase {
        case .idle:
            guard let target else { return [] }
            return arm(target, moved: moved)
        case .pending(let pending, _):
            guard let target else { return end() }
            if target.id == pending.id { return [] }
            return arm(target, moved: moved)
        case .grace:
            guard let target else { return [] }
            phase = .shown(target)
            return [.cancelTimer, .show(target, sliding: false)]
        case .shown(let shown):
            guard let target else {
                let token = takeToken()
                phase = .leaving(shown, token: token)
                return [.schedule(token: token, after: leaveWindow)]
            }
            if target.id == shown.id {
                // The target moved or resized: the coordinator moves the card.
                phase = .shown(target)
                return []
            }
            phase = .shown(target)
            return [.show(target, sliding: true)]
        case .leaving(let shown, _):
            guard let target else { return [] }
            phase = .shown(target)
            return target.id == shown.id ? [.cancelTimer] : [.cancelTimer, .show(target, sliding: true)]
        case .pinned(let shown, let token):
            // The pointer leaving keeps a pinned card, and so does content
            // moving under a still pointer; a pointer that moves onto
            // another target takes over.
            guard let target else { return [] }
            if target.id == shown.id {
                phase = .pinned(target, token: token)
                return []
            }
            guard moved else { return [] }
            phase = .shown(target)
            return [.cancelTimer, .show(target, sliding: true)]
        }
    }

    /// From idle, with the pointer resting on a target and nothing keeping
    /// cards away, that target's card starts again (after a pinned card of
    /// another target ended).
    private mutating func resume() -> [HoverCardEffect] {
        guard phase == .idle, suppressions.isEmpty, !quiet, let target = lastHit else { return [] }
        return arm(target, moved: false)
    }

    private mutating func arm(_ target: HoverTarget, moved: Bool) -> [HoverCardEffect] {
        // No delay (the workspace card): a moving pointer's card shows on
        // this hit; content moving under a still pointer waits a moment.
        if target.delay <= .zero, moved {
            let hadTimer = armedToken != nil
            phase = .shown(target)
            return (hadTimer ? [.cancelTimer] : []) + [.show(target, sliding: false)]
        }
        let token = takeToken()
        phase = .pending(target, token: token)
        return [.schedule(token: token, after: target.delay > .zero ? target.delay : stillPointerDelay)]
    }

    /// Back to idle: cancels the timer and hides a shown card.
    private mutating func end() -> [HoverCardEffect] {
        let wasShown = shownTarget != nil
        let hadTimer = armedToken != nil
        phase = .idle
        var effects: [HoverCardEffect] = []
        if hadTimer { effects.append(.cancelTimer) }
        if wasShown { effects.append(.hide) }
        return effects
    }

    private mutating func takeToken() -> Int {
        defer { nextToken += 1 }
        return nextToken
    }
}
