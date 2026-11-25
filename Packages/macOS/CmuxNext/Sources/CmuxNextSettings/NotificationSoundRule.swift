/// One level's sound choices (a workspace, a group, an agent kind): every field nil inherits from the
/// level above. In cmux.json: `{"sound": "Glass", "volume": 0.5, "events": {"needsInput": "Ping"}}`.
public nonisolated struct NotificationSoundRule: Hashable, Sendable {
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
    public var json: JSONValue {
        var members: [String: JSONValue] = [:]
        if let sound { members["sound"] = .string(sound) }
        if let volume { members["volume"] = .number(volume) }
        if !events.isEmpty {
            members["events"] = .object(Dictionary(uniqueKeysWithValues: events.map { ($0.key.rawValue, JSONValue.string($0.value)) }))
        }
        return .object(members)
    }

    /// The rule in `value`. A plain string is shorthand for `{"sound": value}`. Nil, with a
    /// message, when `value` is neither; a bad member is dropped with a message and the rest apply.
    /// Asked of cmux-window-rules (`window_notifications_sound_rule_parse`); nil when it does not answer.
    public static func parse(_ value: JSONValue, problems: inout [String]) -> NotificationSoundRule? {
        guard let reply = ask(value) else { return nil }
        problems += reply.problems
        return reply.rule?.rule
    }

    /// Whether `value` is a rule cmux.json can hold (the schema's check before a write).
    public static func accepts(_ value: JSONValue) -> Bool {
        ask(value)?.accepts ?? false
    }
}
