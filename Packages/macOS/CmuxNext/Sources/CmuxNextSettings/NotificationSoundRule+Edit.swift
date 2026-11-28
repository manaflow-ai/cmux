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
        let reply = SettingsRust.answer("notifications.rule_apply", [
            "rule": SettingsRust.json(self), "sound": sound.map(JSONValue.string) ?? .null,
            "event": event.map { .string($0.rawValue) } ?? .null, "volume": volume.map(JSONValue.number) ?? .null,
        ])
        return SettingsRust.decode(reply["rule"]) ?? self
    }
}
