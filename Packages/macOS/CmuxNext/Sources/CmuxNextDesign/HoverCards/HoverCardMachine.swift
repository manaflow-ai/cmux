public import Foundation

/// A thing that can have a hover card (a tab, a group chip, a sidebar
/// workspace row), named by a stable id, never by a view.
public nonisolated struct HoverTargetID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// What the reducer needs to know about a target: its id, its window and
/// how long the pointer must rest on it before its card shows.
public nonisolated struct HoverTarget: Hashable, Sendable {
    public var id: HoverTargetID
    public var window: Int
    public var delay: Duration

    public init(id: HoverTargetID, window: Int, delay: Duration) {
        self.id = id
        self.window = window
        self.delay = delay
    }
}

/// Ends any card at once and keeps cards away until the pointer moves.
public nonisolated enum HoverDismissal: String, Hashable, Sendable, CaseIterable {
    case keyDown, click, scrollWheel, menuOpened, windowResignedKey, appDeactivated, action
}

/// Keeps cards away while it lasts.
public nonisolated enum HoverSuppression: String, Hashable, Sendable, CaseIterable {
    case drag, scroll
}

/// Inputs of the hover card state machine.
public nonisolated enum HoverCardEvent: Hashable, Sendable {
    /// What is under the pointer now: after a pointer move (`moved` true), or
    /// after content moved under a still pointer (layout, scroll, column
    /// scroll, window move: `moved` false), from a fresh hit test.
    case hit(HoverTarget?, moved: Bool)
    /// The one-shot timer for `token` fired.
    case deadline(token: Int)
    case dismiss(HoverDismissal)
    case suppress(HoverSuppression)
    case unsuppress(HoverSuppression)
    /// The target is gone (tab closed, workspace removed, strip torn down).
    case targetRemoved(HoverTargetID)
    /// Show `target`'s card now, until a dismissal (Show Resource Usage).
    case pin(HoverTarget)
}

/// Outputs: what the coordinator does to the one card and the one timer.
public nonisolated enum HoverCardEffect: Hashable, Sendable {
    /// Arms the one timer for `token` (replacing any armed one).
    case schedule(token: Int, after: Duration)
    case cancelTimer
    /// Shows the card for `target`, or moves it there and updates it.
    /// `sliding`: the card was visible for another target and slides over.
    case show(HoverTarget, sliding: Bool)
    case hide
}

/// The hover card state machine (plans/cmux-next/hovercards.md). One per
/// app: there is one phase, so at most one card is pending or shown.
/// Pure: the coordinator feeds it events and runs its effects.
public nonisolated struct HoverCardMachine: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        case idle
        /// The pointer rests on `target`; its card shows when `token` fires.
        case pending(HoverTarget, token: Int)
        /// The card shows `target`. A pinned card stays when the pointer
        /// leaves; only a dismissal ends it.
        case shown(HoverTarget, pinned: Bool)
        /// A card just hid; a hover before `token` fires shows at once
        /// (Chrome's quick reshow).
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

    public init(reshowWindow: Duration = .milliseconds(700)) {
        self.reshowWindow = reshowWindow
    }

    /// The target whose card is pending or shown.
    public var activeTarget: HoverTarget? {
        switch phase {
        case .pending(let target, _), .shown(let target, _): target
        case .idle, .grace: nil
        }
    }

    public var shownTarget: HoverTarget? {
        if case .shown(let target, _) = phase { return target }
        return nil
    }

    /// The token the armed timer carries, if one should be armed.
    public var armedToken: Int? {
        switch phase {
        case .pending(_, let token), .grace(let token): token
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
                phase = .shown(target, pinned: false)
                return [.show(target, sliding: false)]
            case .grace(let armed) where armed == token:
                phase = .idle
                return []
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
            return []
        case .targetRemoved(let id):
            if lastHit?.id == id { lastHit = nil }
            guard activeTarget?.id == id else { return [] }
            return end()
        case .pin(let target):
            // No card during a drag or scroll, pinned or not.
            guard suppressions.isEmpty else { return [] }
            quiet = false
            let wasShown = shownTarget != nil
            phase = .shown(target, pinned: true)
            return [.cancelTimer, .show(target, sliding: wasShown)]
        }
    }

    private mutating func hit(_ target: HoverTarget?, moved: Bool) -> [HoverCardEffect] {
        let previous = lastHit
        lastHit = target
        if moved { quiet = false }
        if !suppressions.isEmpty {
            return phase == .idle ? [] : end()
        }
        // A still pointer after a dismissal starts nothing on the target it
        // was already on; a different target moving under it may.
        if quiet, !moved, target?.id == previous?.id {
            if case .shown(let shown, _) = phase, shown.id == target?.id { return [] }
            return phase == .idle ? [] : end()
        }
        switch phase {
        case .idle:
            guard let target else { return [] }
            return arm(target)
        case .pending(let pending, _):
            guard let target else { return end() }
            if target.id == pending.id { return [] }
            return arm(target)
        case .grace:
            guard let target else { return [] }
            phase = .shown(target, pinned: false)
            return [.cancelTimer, .show(target, sliding: false)]
        case .shown(let shown, let pinned):
            guard let target else {
                if pinned { return [] }
                let token = takeToken()
                phase = .grace(token: token)
                return [.hide, .schedule(token: token, after: reshowWindow)]
            }
            if target.id == shown.id {
                // The target moved or changed: the card follows it.
                phase = .shown(target, pinned: pinned)
                return target == shown ? [] : [.show(target, sliding: false)]
            }
            phase = .shown(target, pinned: false)
            return [.show(target, sliding: true)]
        }
    }

    private mutating func arm(_ target: HoverTarget) -> [HoverCardEffect] {
        let token = takeToken()
        phase = .pending(target, token: token)
        return [.schedule(token: token, after: target.delay)]
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
