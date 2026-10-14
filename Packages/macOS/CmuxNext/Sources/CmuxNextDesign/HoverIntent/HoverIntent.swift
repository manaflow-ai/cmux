public import Foundation

/// The app's one hover-intent policy (Leo, 2026-10-14: tooltips and hover
/// cards appeared at once everywhere). Tooltips wait before the first one
/// shows, then a neighbor's shows at once while the group is warm; hover
/// cards wait longer, stay while the pointer heads into them, and linger a
/// moment after it leaves. Pages use the same numbers
/// (webviews/src/ui/hoverIntent.ts, `HOVER_INTENT`; a web test reads this
/// file and fails when they drift).
///
/// Apple's numbers: AppKit's tooltip waits `NSInitialToolTipDelay`
/// (milliseconds; about 1000 ms at the default setting), and once one
/// shows, the next view's tooltip shows at once. 800 ms is the step under
/// that: close enough to read as the Mac's own, short enough that a
/// deliberate rest is not a wait. Each value is a tunable (Debug >
/// Tunables > Hover).
public nonisolated struct HoverIntentTiming: Hashable, Sendable {
    /// Pointer rest before the first tooltip of a group shows.
    public var tooltipDelay: Duration
    /// After the last tooltip hid, how long the next one still shows at once.
    public var tooltipWarm: Duration
    /// Pointer rest on a sidebar row before its hover card shows.
    public var cardDwell: Duration
    /// How long a card stays after the pointer leaves its target and the card.
    public var cardGrace: Duration
    /// How long a pointer heading for a shown card may pause on another
    /// target it crosses before that target's card takes over.
    public var cardAim: Duration

    public init(tooltipDelay: Duration, tooltipWarm: Duration, cardDwell: Duration, cardGrace: Duration, cardAim: Duration) {
        self.tooltipDelay = tooltipDelay
        self.tooltipWarm = tooltipWarm
        self.cardDwell = cardDwell
        self.cardGrace = cardGrace
        self.cardAim = cardAim
    }

    /// The defaults (`HOVER_INTENT` in webviews/src/ui/hoverIntent.ts mirrors these).
    public static let standard = HoverIntentTiming(
        tooltipDelay: .milliseconds(800), tooltipWarm: .milliseconds(500), cardDwell: .milliseconds(1_000),
        cardGrace: .milliseconds(200), cardAim: .milliseconds(300))

    /// The values now, with any tunable override.
    public static var current: HoverIntentTiming {
        HoverIntentTiming(
            tooltipDelay: duration(MotionTunables.tooltipDelay.value), tooltipWarm: duration(MotionTunables.tooltipWarm.value),
            cardDwell: duration(MotionTunables.hoverCardDwell.value), cardGrace: duration(MotionTunables.hoverCardGrace.value),
            cardAim: duration(MotionTunables.hoverCardAim.value))
    }

    private static func duration(_ seconds: Double) -> Duration { .milliseconds(Int((max(0, seconds) * 1_000).rounded())) }
}

/// Hover intent for one warm group of tooltips: a target under the pointer
/// shows after `tooltipDelay`, or at once while the group is warm (a
/// tooltip shows, or hid less than `tooltipWarm` ago). Moving to another
/// target before the delay restarts it, so a sweep shows nothing. Pure: its
/// owner feeds it the target under the pointer and timer deadlines, and
/// runs the effects on its one timer.
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

    public private(set) var phase: Phase = .idle
    private var nextToken = 1
    public var delay: Duration
    public var warmFor: Duration

    public init(delay: Duration, warmFor: Duration) {
        self.delay = delay
        self.warmFor = warmFor
    }

    public var shown: Target? {
        if case .shown(let target) = phase { return target }
        return nil
    }

    public var isWarm: Bool {
        switch phase {
        case .shown, .warm: true
        case .idle, .pending: false
        }
    }

    /// The target under the pointer now (nil: none).
    public mutating func hover(_ target: Target?) -> [Effect] {
        switch phase {
        case .idle:
            guard let target else { return [] }
            return arm(target)
        case .pending(let pending, _):
            guard let target else {
                phase = .idle
                return [.cancelTimer]
            }
            return target == pending ? [] : arm(target)
        case .shown(let shown):
            guard let target else {
                let token = takeToken()
                phase = .warm(token: token)
                return [.hide, .schedule(token: token, after: warmFor)]
            }
            if target == shown { return [] }
            phase = .shown(target)
            return [.show(target)]
        case .warm:
            guard let target else { return [] }
            phase = .shown(target)
            return [.cancelTimer, .show(target)]
        }
    }

    public mutating func deadline(_ token: Int) -> [Effect] {
        switch phase {
        case .pending(let target, let armed) where armed == token:
            phase = .shown(target)
            return [.show(target)]
        case .warm(let armed) where armed == token:
            phase = .idle
            return []
        default:
            return []
        }
    }

    /// A click, a key or a scroll: whatever shows goes, and the group is cold again.
    public mutating func dismiss() -> [Effect] {
        let effects: [Effect] = switch phase {
        case .idle: []
        case .pending, .warm: [.cancelTimer]
        case .shown: [.hide]
        }
        phase = .idle
        return effects
    }

    private mutating func arm(_ target: Target) -> [Effect] {
        guard delay > .zero else {
            phase = .shown(target)
            return [.show(target)]
        }
        let token = takeToken()
        phase = .pending(target, token: token)
        return [.schedule(token: token, after: delay)]
    }

    private mutating func takeToken() -> Int {
        defer { nextToken += 1 }
        return nextToken
    }
}

/// The safe triangle (Amazon's menu aim, macOS submenus).
nonisolated extension CGRect {
    /// Whether a pointer moving from `from` to `to` heads for this rect (a
    /// shown card): `to` lies in it, or in the triangle from `from` to its
    /// nearer edge. A target it crosses on the way then does not take the
    /// card over. Screen coordinates; webviews/src/ui/hoverIntent.ts
    /// (`aimingAt`) has the same test.
    public func isAimedAt(from: CGPoint?, to: CGPoint?) -> Bool {
        guard let from, let to, width > 0, height > 0, from != to else { return false }
        if contains(to) { return true }
        let beside = from.x < minX || from.x > maxX
        let a: CGPoint
        let b: CGPoint
        if beside {
            let x = from.x < minX ? minX : maxX
            a = CGPoint(x: x, y: minY)
            b = CGPoint(x: x, y: maxY)
        } else {
            let y = from.y < minY ? minY : maxY
            a = CGPoint(x: minX, y: y)
            b = CGPoint(x: maxX, y: y)
        }
        // Inside the triangle `from a b` (either winding).
        func side(_ p: CGPoint, _ q: CGPoint) -> CGFloat { (q.x - p.x) * (to.y - p.y) - (q.y - p.y) * (to.x - p.x) }
        let ab = side(from, a)
        let bc = side(a, b)
        let ca = side(b, from)
        return (ab >= 0 && bc >= 0 && ca >= 0) || (ab <= 0 && bc <= 0 && ca <= 0)
    }
}
