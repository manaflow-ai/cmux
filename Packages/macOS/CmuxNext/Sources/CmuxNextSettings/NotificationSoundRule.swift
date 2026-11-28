/// One level's sound choices (a workspace, a group, an agent kind): every field nil inherits from the
/// level above. In cmux.json: `{"sound": "Glass", "volume": 0.5, "events": {"needsInput": "Ping"}}`.
public nonisolated struct NotificationSoundRule: Hashable, Sendable, Codable {
    /// The sound of every event at this level: a sound name, a file path, `"default"` or `"none"`
    /// (mute this level). Nil inherits.
    public var sound: String?
    /// 0 to 1, times the master volume (`notifications.sounds.volume`). Nil inherits.
    public var volume: Double?
    /// One event's sound at this level; it wins over `sound`.
    public var events: [NotificationSoundEvent: String] = [:]

    public init(sound: String? = nil, volume: Double? = nil, events: [NotificationSoundEvent: String] = [:]) {
        self.sound = sound
        self.volume = volume
        self.events = events
    }

    /// True when every field inherits: the level can be removed from cmux.json.
    public var isEmpty: Bool { sound == nil && volume == nil && events.isEmpty }

    /// The sound this level sets for `event`: its event's own, else its `sound`; nil inherits.
    public func sound(for event: NotificationSoundEvent) -> String? {
        events[event] ?? sound
    }

    /// The rule as cmux.json writes it.
    public var json: JSONValue { SettingsRust.json(self) }

    /// The rule in `value` (Rust `notifications.rule_parse`). A plain string is shorthand for
    /// `{"sound": value}`. Nil, with a message, when `value` is neither; a bad member is dropped
    /// with a message and the rest apply.
    public static func parse(_ value: JSONValue, problems: inout [String]) -> NotificationSoundRule? {
        let reply = SettingsRust.answer("notifications.rule_parse", ["value": value])
        problems += (reply["problems"]?.arrayValue ?? []).compactMap(\.stringValue)
        return SettingsRust.decode(reply["rule"])
    }

    /// Whether `value` is a rule cmux.json can hold (the schema's check before a write).
    public static func accepts(_ value: JSONValue) -> Bool {
        SettingsRust.answer("notifications.rule_accepts", ["value": value])["accepts"]?.boolValue ?? false
    }

    private enum CodingKeys: String, CodingKey { case sound, volume, events }

    /// Rust leaves out an inheriting member, as cmux.json does.
    public init(from decoder: any Decoder) throws {
        let members = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sound: try members.decodeIfPresent(String.self, forKey: .sound),
                  volume: try members.decodeIfPresent(Double.self, forKey: .volume),
                  events: try members.decodeIfPresent([NotificationSoundEvent: String].self, forKey: .events) ?? [:])
    }

    public func encode(to encoder: any Encoder) throws {
        var members = encoder.container(keyedBy: CodingKeys.self)
        try members.encodeIfPresent(sound, forKey: .sound)
        try members.encodeIfPresent(volume, forKey: .volume)
        if !events.isEmpty { try members.encode(events, forKey: .events) }
    }
}
