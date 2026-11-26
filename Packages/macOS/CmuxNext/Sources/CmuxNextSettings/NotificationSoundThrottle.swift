import CmuxNextWindowRules

/// Keeps a burst of notifications (ten agents finishing at once) from stacking ten sounds: after a
/// sound, an event no more urgent than it stays silent for the cooldown. A more urgent event (an agent
/// asking for input after a run of finishes) still plays, so the sound that matters is never lost.
/// The rule is Rust's (cmux-window-rules `notification_policy::admit`, op
/// `window_notifications_sound_admit`); this keeps the last sound and the clock. The caller passes the
/// time, tests pass their own.
public nonisolated struct NotificationSoundThrottle: Sendable {
    public var cooldown: Duration
    private var last: Last?

    private struct Last: Codable, Sendable {
        var atMs: Int64
        var urgency: Int
    }

    public init(cooldown: Duration) {
        self.cooldown = cooldown
    }

    /// Whether `event` may sound at `now`; a yes is recorded as the newest sound.
    public mutating func admit(_ event: NotificationSoundEvent, at now: ContinuousClock.Instant) -> Bool {
        struct Request: Encodable { var last: Last?, event: String, nowMs: Int64, cooldownMs: Int64 }
        struct Reply: Decodable { var admitted: Bool, last: Last? }
        let request = Request(last: last, event: event.rawValue, nowMs: Self.milliseconds(Self.origin.duration(to: now)),
                              cooldownMs: Self.milliseconds(cooldown))
        // An FFI without the op answers nothing: the sound plays, as with no cooldown.
        guard let reply = WindowRules().call("window_notifications_sound_admit", request, as: Reply.self) else { return true }
        if reply.admitted { last = reply.last }
        return reply.admitted
    }

    /// The clock's zero for the milliseconds the rule reads.
    private static let origin = ContinuousClock.now

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }
}
