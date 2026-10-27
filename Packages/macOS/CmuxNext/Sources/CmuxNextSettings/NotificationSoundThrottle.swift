/// Keeps a burst of notifications (ten agents finishing at once) from stacking ten sounds: after a
/// sound, an event no more urgent than it stays silent for the cooldown. A more urgent event (an agent
/// asking for input after a run of finishes) still plays, so the sound that matters is never lost.
/// Pure: the caller passes the time, tests pass their own.
public nonisolated struct NotificationSoundThrottle: Sendable {
    public var cooldown: Duration
    private var last: (at: ContinuousClock.Instant, urgency: Int)?

    public init(cooldown: Duration) {
        self.cooldown = cooldown
    }

    /// Whether `event` may sound at `now`; a yes is recorded as the newest sound.
    public mutating func admit(_ event: NotificationSoundEvent, at now: ContinuousClock.Instant) -> Bool {
        if let last, now - last.at < cooldown, event.urgency <= last.urgency { return false }
        last = (now, event.urgency)
        return true
    }
}
