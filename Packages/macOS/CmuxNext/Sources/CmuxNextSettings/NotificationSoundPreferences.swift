import CmuxNextWindowRules

/// `notifications.sounds` in cmux.json: per-event sounds, master volume, when sounds play, the
/// burst cooldown, and the levels a workspace, a group or an agent kind can override.
///
/// ```json
/// "notifications": {
///   "sound": "Glass",
///   "sounds": {
///     "volume": 0.8,
///     "maxSeconds": 3,
///     "when": "unlessViewed",
///     "cooldownSeconds": 1.5,
///     "events": {"needsInput": "Ping", "error": "Basso"},
///     "groups": {"Agents & routing": {"sound": "Submarine", "volume": 0.5}},
///     "workspaces": {"ws_1": "none"},
///     "agents": {"codex": {"events": {"finished": "Hero"}}}
///   }
/// }
/// ```
public nonisolated struct NotificationSoundPreferences: Hashable, Sendable {
    /// Master volume, 0 to 1; every level's volume is a share of it.
    public var volume: Double = Self.volumeDefault
    /// Each sound cmux plays itself stops after this many seconds; 0 plays it to its end.
    public var maxSeconds: Double = Self.maxSecondsDefault
    public var when: NotificationSoundTiming = Self.whenDefault
    /// After a sound, quieter or equal events wait this long before the next one plays, so many
    /// agents finishing together sound once. 0 turns it off.
    public var cooldownSeconds: Double = Self.cooldownDefault
    /// The global sound of one event; nil keeps `notifications.sound` (or its source's sound).
    public var events: [NotificationSoundEvent: String] = [:]
    /// Group rules by group id or name.
    public var groups: [String: NotificationSoundRule] = [:]
    /// Workspace rules by workspace id.
    public var workspaces: [String: NotificationSoundRule] = [:]
    /// Agent-kind rules (`claude`, `codex`), lowercased.
    public var agents: [String: NotificationSoundRule] = [:]

    public init() {}

    /// The sound `event` plays in `scope`: the most specific level that names one wins (the agent
    /// kind, the workspace, then each group from the innermost out), then the event's global sound,
    /// then `fallback` (`notifications.sound`, or its source's). `"none"` anywhere on that path mutes
    /// it (nil). The volume is the most specific level's that sets one, times the master volume.
    /// Rust's rule (op `window_notifications_sound_choice`).
    public func choice(for event: NotificationSoundEvent, in scope: NotificationSoundScope, fallback: String) -> NotificationSoundChoice? {
        struct Request: Encodable { var sounds: Wire, event: String, scope: NotificationSoundScope.Wire, fallback: String }
        struct Choice: Decodable { var name: String, volume: Double, level: String }
        struct Reply: Decodable { var choice: Choice? }
        let request = Request(sounds: Wire(self), event: event.rawValue, scope: NotificationSoundScope.Wire(scope), fallback: fallback)
        guard let choice = WindowRules().call("window_notifications_sound_choice", request, as: Reply.self)?.choice else { return nil }
        return NotificationSoundChoice(name: choice.name, volume: choice.volume, level: choice.level)
    }
}
