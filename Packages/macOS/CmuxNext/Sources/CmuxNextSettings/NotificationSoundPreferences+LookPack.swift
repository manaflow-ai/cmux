/// The active look's sound pack (`notifications.sounds.lookPack`, a theme file's `"sounds"` block):
/// a sound for an agent that finished, one that needs you, and a chat whose checks went green. Off by
/// default: a look changes no sound until the person turns its pack on.
extension NotificationSoundPreferences {
    /// The moments a look's sound pack may sound for, as a theme file names them.
    public nonisolated enum LookEvent: String, Hashable, Sendable, CaseIterable {
        /// An agent finished its turn (``NotificationSoundEvent/finished``).
        case finished
        /// An agent needs you (``NotificationSoundEvent/needsInput``).
        case needsInput
        /// A chat's pull request checks went green.
        case ciGreen

        /// The look event a notification event plays; nil for the events a pack does not cover.
        public init?(_ event: NotificationSoundEvent) {
            switch event {
            case .finished: self = .finished
            case .needsInput: self = .needsInput
            case .error, .bell, .message: return nil
            }
        }
    }

    /// The pack's sound for `event` when the person turned the pack on, else nil.
    public func lookSound(for event: LookEvent) -> String? {
        lookPack ? lookSounds[event] : nil
    }

    /// The pack's sound for a moment no notification carries (a chat's checks going green), with
    /// every mute the notification sounds obey: the pack is off or names no sound, the event's sound
    /// or the global sound (`fallback`) is `"none"`, or the master volume is 0. Quiet hours are the
    /// caller's (``NotificationPreferences/lookSound(for:minuteOfDay:)``).
    public func lookChoice(for event: LookEvent, fallback: String) -> NotificationSoundChoice? {
        guard let name = lookSound(for: event), name != "none", !name.isEmpty, fallback != "none", volume > 0 else { return nil }
        return NotificationSoundChoice(name: name, volume: min(max(volume, 0), 1), level: "look:\(event.rawValue)")
    }
}

extension NotificationPreferences {
    /// The look's sound for `event` at `minuteOfDay` (minutes past local midnight): nil when the pack
    /// is off, quiet hours hold, or a mute applies (``NotificationSoundPreferences/lookChoice(for:fallback:)``).
    public func lookSound(for event: NotificationSoundPreferences.LookEvent, minuteOfDay: Int) -> NotificationSoundChoice? {
        if quietHours?.contains(minuteOfDay: minuteOfDay) == true { return nil }
        return sounds.lookChoice(for: event, fallback: sound)
    }
}
