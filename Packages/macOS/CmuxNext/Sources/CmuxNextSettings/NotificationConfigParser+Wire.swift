import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWindowRules

/// What cmux-window-rules `notification_settings` answers (`window_notifications_settings_parse`,
/// `_sound_rule_parse`): the preferences and diagnostics as the app's types. No rule lives here;
/// an unknown raw value keeps the field's default.
extension NotificationConfigParser {
    struct Parsed: Decodable {
        var prefs: Prefs
        var diagnostics: [Diagnostic]

        struct Diagnostic: Decodable {
            var path: String, message: String

            var diagnostic: SettingsDiagnostic { SettingsDiagnostic(kind: .invalidValue, path: path, message: message) }
        }
    }

    struct Prefs: Decodable {
        struct Hours: Decodable { var start: Int, end: Int }
        struct Color: Decodable { var hex: UInt32, alpha: Double }
        struct Source: Decodable { var dismissal: String?, color: Color?, sound: String?, desktop: Bool? }
        struct Mirror: Decodable { var agents: Bool, terminal: String, agentPermissionPrompts: Bool }
        struct Sounds: Decodable {
            var volume: Double, maxSeconds: Double, when: String, cooldownSeconds: Double
            var events: [String: String]
            var groups: [String: NotificationSoundRule.Wire], workspaces: [String: NotificationSoundRule.Wire]
            var agents: [String: NotificationSoundRule.Wire]
        }

        var dismissal: String, timeoutSeconds: Double, desktop: String, sound: String
        var sounds: Sounds, quietHours: Hours?, suppressWhileTypingSeconds: Double
        var dockBadge: Bool, dockBounce: String, showPreviews: String, toastStyle: String
        var mutedWorkspaces: [String], sources: [String: Source], feedMirror: Mirror

        var preferences: NotificationPreferences {
            var prefs = NotificationPreferences()
            prefs.dismissal = NotificationDismissal(rawValue: dismissal) ?? prefs.dismissal
            prefs.timeoutSeconds = timeoutSeconds
            prefs.desktop = DesktopNotificationMode(rawValue: desktop) ?? prefs.desktop
            prefs.sound = sound
            prefs.sounds = soundPreferences
            prefs.quietHours = quietHours.map { QuietHours(start: $0.start, end: $0.end) }
            prefs.suppressWhileTypingSeconds = suppressWhileTypingSeconds
            prefs.dockBadge = dockBadge
            prefs.dockBounce = DockBounceMode(rawValue: dockBounce) ?? prefs.dockBounce
            prefs.showPreviews = NotificationPreviews(rawValue: showPreviews) ?? prefs.showPreviews
            prefs.toastStyle = CmuxToastStyle(rawValue: toastStyle) ?? prefs.toastStyle
            prefs.mutedWorkspaces = Set(mutedWorkspaces)
            for (name, wire) in sources {
                guard let source = NotificationSource(rawValue: name) else { continue }
                var overrides = NotificationSourceOverrides()
                overrides.dismissal = wire.dismissal.flatMap(NotificationDismissal.init(rawValue:))
                overrides.color = wire.color.map { ThemeRGB(hex: $0.hex, alpha: $0.alpha) }
                overrides.sound = wire.sound
                overrides.desktop = wire.desktop
                prefs.sources[source] = overrides
            }
            prefs.feedMirror.agents = feedMirror.agents
            prefs.feedMirror.terminal = FeedTerminalMirror(rawValue: feedMirror.terminal) ?? prefs.feedMirror.terminal
            prefs.feedMirror.agentPermissionPrompts = feedMirror.agentPermissionPrompts
            return prefs
        }

        private var soundPreferences: NotificationSoundPreferences {
            var prefs = NotificationSoundPreferences()
            prefs.volume = sounds.volume
            prefs.maxSeconds = sounds.maxSeconds
            prefs.when = NotificationSoundTiming(rawValue: sounds.when) ?? prefs.when
            prefs.cooldownSeconds = sounds.cooldownSeconds
            prefs.events = NotificationSoundRule.Wire.events(sounds.events)
            prefs.groups = sounds.groups.mapValues(\.rule)
            prefs.workspaces = sounds.workspaces.mapValues(\.rule)
            prefs.agents = sounds.agents.mapValues(\.rule)
            return prefs
        }
    }
}

extension NotificationSoundRule {
    /// One level's rule as cmux-window-rules `SoundRule` answers it (an absent field inherits).
    struct Wire: Decodable {
        var sound: String?, volume: Double?, events: [String: String]

        enum CodingKeys: String, CodingKey { case sound, volume, events }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sound = try container.decodeIfPresent(String.self, forKey: .sound)
            volume = try container.decodeIfPresent(Double.self, forKey: .volume)
            events = try container.decodeIfPresent([String: String].self, forKey: .events) ?? [:]
        }

        var rule: NotificationSoundRule {
            NotificationSoundRule(sound: sound, volume: volume, events: Self.events(events))
        }

        static func events(_ wire: [String: String]) -> [NotificationSoundEvent: String] {
            Dictionary(wire.compactMap { name, sound in NotificationSoundEvent(rawValue: name).map { ($0, sound) } },
                       uniquingKeysWith: { first, _ in first })
        }
    }

    /// `window_notifications_sound_rule_parse`'s answer: the rule (nil: refused), its problems,
    /// and whether cmux.json can hold it.
    struct ParseReply: Decodable {
        var rule: Wire?, problems: [String], accepts: Bool
    }

    struct ParseRequest: Encodable { var value: JSONValue }

    static func ask(_ value: JSONValue) -> ParseReply? {
        WindowRules().call("window_notifications_sound_rule_parse", ParseRequest(value: value), as: ParseReply.self)
    }
}
