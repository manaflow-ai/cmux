/// `notifications.sounds` in cmux.json: per-event sounds, master volume, when sounds play, the
/// burst cooldown, and the levels a workspace, a group or an agent kind can override.
///
/// ```json
/// "notifications": {
///   "sound": "Glass",
///   "sounds": {
///     "volume": 0.8,
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
    public var volume: Double = 1
    public var when: NotificationSoundTiming = .unlessViewed
    /// After a sound, quieter or equal events wait this long before the next one plays, so many
    /// agents finishing together sound once. 0 turns it off.
    public var cooldownSeconds: Double = 1.5
    /// The global sound of one event; nil keeps `notifications.sound` (or its source's sound).
    public var events: [NotificationSoundEvent: String] = [:]
    /// Group rules by group id or name.
    public var groups: [String: NotificationSoundRule] = [:]
    /// Workspace rules by workspace id.
    public var workspaces: [String: NotificationSoundRule] = [:]
    /// Agent-kind rules (`claude`, `codex`), lowercased.
    public var agents: [String: NotificationSoundRule] = [:]

    public init() {}

    public static let volumeRange: ClosedRange<Double> = 0...1
    public static let cooldownRange: ClosedRange<Double> = 0...60

    /// The levels that apply to `scope`, most specific first: the agent kind, the workspace, then
    /// each group from the innermost out.
    public func levels(for scope: NotificationSoundScope) -> [(name: String, rule: NotificationSoundRule)] {
        var levels: [(name: String, rule: NotificationSoundRule)] = []
        if let agent = scope.agent?.lowercased(), let rule = agents[agent] { levels.append(("agent:\(agent)", rule)) }
        if let workspace = scope.workspace, let rule = workspaces[workspace] { levels.append(("workspace:\(workspace)", rule)) }
        for group in scope.groups {
            if let rule = groups[group.id] ?? groups[group.name] { levels.append(("group:\(group.name)", rule)) }
        }
        return levels
    }

    /// The sound `event` plays in `scope`: the most specific level that names one wins, then the
    /// event's global sound, then `fallback` (`notifications.sound`, or its source's). `"none"`
    /// anywhere on that path mutes it (nil). The volume is the most specific level's that sets one,
    /// times the master volume.
    public func choice(for event: NotificationSoundEvent, in scope: NotificationSoundScope, fallback: String) -> NotificationSoundChoice? {
        let levels = levels(for: scope)
        let picked = levels.lazy.compactMap { level in level.rule.sound(for: event).map { (name: $0, level: level.name) } }.first
            ?? events[event].map { (name: $0, level: "event:\(event.rawValue)") }
            ?? (name: fallback, level: "global")
        guard picked.name != "none", !picked.name.isEmpty else { return nil }
        let share = levels.lazy.compactMap { $0.rule.volume }.first ?? 1
        return NotificationSoundChoice(name: picked.name, volume: min(max(share * volume, 0), 1), level: picked.level)
    }
}
