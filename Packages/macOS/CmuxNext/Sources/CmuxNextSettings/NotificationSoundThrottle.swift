/// Keeps a burst of notifications (ten agents finishing at once) from stacking ten sounds: after a
/// sound, an event no more urgent than it stays silent for the cooldown. A more urgent event (an agent
/// asking for input after a run of finishes) still plays, so the sound that matters is never lost.
/// The rule is Rust's (`notifications.sound_admit`); the caller passes the time, tests pass their own.
public nonisolated struct NotificationSoundThrottle: Sendable {
    public var cooldown: Duration
    /// The first admit's instant: the op takes times as seconds after it.
    private var origin: ContinuousClock.Instant?
    /// The newest sound, as the op answered it (`{at, urgency}`).
    private var last: JSONValue?

    public init(cooldown: Duration) {
        self.cooldown = cooldown
    }

    /// Whether `event` may sound at `now`; a yes is recorded as the newest sound.
    public mutating func admit(_ event: NotificationSoundEvent, at now: ContinuousClock.Instant) -> Bool {
        let origin = self.origin ?? now
        self.origin = origin
        var request: [String: JSONValue] = [
            "event": .string(event.rawValue),
            "now": .number(Self.seconds(now - origin)),
            "cooldownSeconds": .number(Self.seconds(cooldown)),
        ]
        if let last { request["last"] = last }
        let reply = SettingsRust.answer("notifications.sound_admit", .object(request))
        if let newest = reply["last"], !newest.isNull { last = newest }
        return reply["admit"]?.boolValue ?? true
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
