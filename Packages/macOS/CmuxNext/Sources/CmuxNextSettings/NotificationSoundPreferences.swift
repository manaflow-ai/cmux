import Foundation

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
///     "maxSeconds": 4,
///     "lengths": {"Long Chime": "2.5", "~/Sounds/fanfare.m4a": "0"},
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
    public var when: NotificationSoundTiming = Self.whenDefault
    /// After a sound, quieter or equal events wait this long before the next one plays, so many
    /// agents finishing together sound once. 0 turns it off.
    public var cooldownSeconds: Double = Self.cooldownDefault
    /// The longest a sound cmux plays itself lasts, in seconds; a shorter file ends on its own. 0 plays
    /// every file to its end (`notifications.sounds.maxSeconds`).
    public var maxSeconds: Double = Self.maxLengthDefault
    /// How long one sound plays, in seconds, by its sound name or file path (`notifications.sounds.lengths`).
    /// It wins over ``maxSeconds``; 0 plays that file to its end.
    public var lengths: [String: Double] = [:]
    /// The global sound of one event; nil keeps `notifications.sound` (or its source's sound).
    public var events: [NotificationSoundEvent: String] = [:]
    /// Group rules by group id or name.
    public var groups: [String: NotificationSoundRule] = [:]
    /// Workspace rules by workspace id.
    public var workspaces: [String: NotificationSoundRule] = [:]
    /// Agent-kind rules (`claude`, `codex`), lowercased.
    public var agents: [String: NotificationSoundRule] = [:]

    public init() {}

    /// How long `sound` plays before cmux stops it, in seconds; nil plays the file to its end. The
    /// sound's own entry in ``lengths`` wins, then ``maxSeconds``. A file shorter than the length
    /// ends on its own.
    ///
    /// An entry names a sound the way the person writes it: an entry with a path (`~/…`, `/…`) matches
    /// that file first; otherwise a sound matches by name, ignoring case and an audio extension, so
    /// `"glass"`, `"Glass.aiff"` and `"/System/Library/Sounds/Glass.aiff"` all name Glass.
    public func length(for sound: String) -> Double? {
        let wanted = SoundKey(sound)
        var byName: Double?
        for (key, seconds) in lengths.sorted(by: { $0.key < $1.key }) {
            let entry = SoundKey(key)
            if let path = entry.path, path == wanted.path { return seconds > 0 ? seconds : nil }
            if byName == nil, entry.stem == wanted.stem { byName = seconds }
        }
        if let own = byName { return own > 0 ? own : nil }
        return maxSeconds > 0 ? maxSeconds : nil
    }

    /// A sound name or path as ``length(for:)`` compares it: its expanded path, if it is one, and its
    /// name without an audio extension, lowercased.
    nonisolated private struct SoundKey {
        let path: String?
        let stem: String

        init(_ raw: String) {
            let text = raw.trimmingCharacters(in: .whitespaces)
            let isPath = text.hasPrefix("/") || text.hasPrefix("~")
            path = isPath ? ((text as NSString).expandingTildeInPath as NSString).standardizingPath : nil
            let name = isPath ? (text as NSString).lastPathComponent : text
            let ext = (name as NSString).pathExtension.lowercased()
            let bare = NotificationSoundLibrary.extensions.contains(ext) ? (name as NSString).deletingPathExtension : name
            stem = bare.lowercased()
        }
    }

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
