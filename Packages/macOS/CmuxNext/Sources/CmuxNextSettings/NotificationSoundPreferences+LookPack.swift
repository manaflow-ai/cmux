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

    /// What a look's pack says for a moment no notification carries (a chat's checks going green, a
    /// chat turn's end): ``lookMoment(for:fallback:)``.
    public nonisolated enum LookMoment: Hashable, Sendable {
        /// The pack is off or names no sound for the moment: the chat's own sound applies.
        case unset
        /// The pack is on and the moment is silent: the pack's own `"none"`, the global sound
        /// (`fallback`) `"none"`, master volume 0, or (the caller's) quiet hours or `sounds.when`.
        /// Nothing plays, not even the built-in sound the pack replaces.
        case muted
        /// The pack's sound.
        case play(NotificationSoundChoice)

        /// The sound to play; nil when the moment is muted or the pack has none.
        public var choice: NotificationSoundChoice? {
            if case .play(let choice) = self { choice } else { nil }
        }
    }

    /// The pack's answer for `event`, with every mute the notification sounds obey: the pack is off
    /// or names no sound (``LookMoment/unset``), or its `"none"`, the global sound (`fallback`)
    /// `"none"` or master volume 0 silence it (``LookMoment/muted``). Quiet hours are the caller's
    /// (``NotificationPreferences/lookSound(for:minuteOfDay:)``).
    public func lookMoment(for event: LookEvent, fallback: String) -> LookMoment {
        guard let name = lookSound(for: event), !name.isEmpty else { return .unset }
        guard name != "none", fallback != "none", volume > 0 else { return .muted }
        return .play(NotificationSoundChoice(name: name, volume: min(max(volume, 0), 1), level: "look:\(event.rawValue)"))
    }
}

extension NotificationPreferences {
    /// The look's answer for `event` at `minuteOfDay` (minutes past local midnight): unset when the
    /// pack is off or has no sound for it, muted when quiet hours hold or a mute applies
    /// (``NotificationSoundPreferences/lookMoment(for:fallback:)``).
    public func lookSound(for event: NotificationSoundPreferences.LookEvent, minuteOfDay: Int) -> NotificationSoundPreferences.LookMoment {
        let moment = sounds.lookMoment(for: event, fallback: sound)
        if moment != .unset, quietHours?.contains(minuteOfDay: minuteOfDay) == true { return .muted }
        return moment
    }
}
