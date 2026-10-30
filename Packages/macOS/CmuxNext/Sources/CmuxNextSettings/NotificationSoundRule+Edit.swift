extension NotificationSoundRule {
    /// The rule after one change from a menu, the palette or the CLI.
    ///
    /// - Parameters:
    ///   - sound: The new sound; `"inherit"` clears it (with `event` nil: the level's sound and
    ///     every event's, so the level inherits again); nil keeps the sound.
    ///   - event: The event the sound is for; nil sets the level's sound for every event (its own
    ///     per-event sounds stay, being more specific).
    ///   - volume: 0 to 1; nil keeps the volume.
    /// - Returns: The changed rule; ``isEmpty`` when the level inherits everything.
    public nonisolated func applying(sound: String?, event: NotificationSoundEvent?, volume: Double?) -> NotificationSoundRule {
        var rule = self
        switch (sound, event) {
        case (nil, _): break
        case ("inherit"?, nil):
            rule.sound = nil
            rule.events = [:]
        case ("inherit"?, let event?): rule.events[event] = nil
        case (let sound?, nil): rule.sound = sound
        case (let sound?, let event?): rule.events[event] = sound
        }
        if let volume { rule.volume = min(max(volume, 0), 1) }
        return rule
    }
}
