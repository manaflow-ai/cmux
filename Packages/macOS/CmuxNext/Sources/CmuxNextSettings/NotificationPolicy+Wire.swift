/// What the Rust notification rules read and answer (`window_notifications_*`): the app's types as
/// cmux-window-rules `notification_policy` names them. No rule lives here.
extension NotificationPolicy.Decision {
    struct Wire: Decodable {
        var acknowledge: Bool, attention: Bool, alerts: Bool, desktop: Bool
        var sound: String?, soundVolume: Double, soundEvent: String, soundLevel: String?
        var timeout: Double?, bounce: String?

        var decision: NotificationPolicy.Decision {
            var decision = NotificationPolicy.Decision()
            decision.acknowledge = acknowledge
            decision.attention = attention
            decision.alerts = alerts
            decision.desktop = desktop
            decision.sound = sound
            decision.soundVolume = soundVolume
            decision.soundEvent = NotificationSoundEvent(rawValue: soundEvent) ?? .message
            decision.soundLevel = soundLevel
            decision.timeout = timeout
            decision.bounce = bounce.flatMap(DockBounceMode.init(rawValue:))
            return decision
        }
    }
}

extension NotificationPolicy.Arrival {
    struct Wire: Encodable {
        var source: String, workspaceMuted: Bool, paneIsViewed: Bool, appActive: Bool, minuteOfDay: Int
        var typedAgo: Double?, bannerAllowed: Bool, soundEvent: String?, soundScope: NotificationSoundScope.Wire

        init(_ arrival: NotificationPolicy.Arrival) {
            source = arrival.source.rawValue
            workspaceMuted = arrival.workspaceMuted
            paneIsViewed = arrival.paneIsViewed
            appActive = arrival.appActive
            minuteOfDay = arrival.minuteOfDay
            typedAgo = arrival.typedAgo
            bannerAllowed = arrival.bannerAllowed
            soundEvent = arrival.soundEvent?.rawValue
            soundScope = NotificationSoundScope.Wire(arrival.soundScope)
        }
    }
}

extension NotificationSoundScope {
    struct Wire: Encodable {
        struct Group: Encodable { var id: String, name: String }
        var agent: String?, workspace: String?, groups: [Group]

        init(_ scope: NotificationSoundScope) {
            agent = scope.agent
            workspace = scope.workspace
            groups = scope.groups.map { Group(id: $0.id, name: $0.name) }
        }
    }
}

extension NotificationSoundRule {
    struct Wire: Encodable {
        var sound: String?, volume: Double?, events: [String: String]

        init(_ rule: NotificationSoundRule) {
            sound = rule.sound
            volume = rule.volume
            events = Dictionary(uniqueKeysWithValues: rule.events.map { ($0.key.rawValue, $0.value) })
        }
    }
}

extension NotificationSoundPreferences {
    struct Wire: Encodable {
        var volume: Double, when: String, events: [String: String]
        var groups: [String: NotificationSoundRule.Wire], workspaces: [String: NotificationSoundRule.Wire]
        var agents: [String: NotificationSoundRule.Wire]

        init(_ sounds: NotificationSoundPreferences) {
            volume = sounds.volume
            when = sounds.when.rawValue
            events = Dictionary(uniqueKeysWithValues: sounds.events.map { ($0.key.rawValue, $0.value) })
            groups = sounds.groups.mapValues(NotificationSoundRule.Wire.init)
            workspaces = sounds.workspaces.mapValues(NotificationSoundRule.Wire.init)
            agents = sounds.agents.mapValues(NotificationSoundRule.Wire.init)
        }
    }
}

extension NotificationPreferences {
    struct Wire: Encodable {
        struct Hours: Encodable { var start: Int, end: Int }
        struct Source: Encodable { var dismissal: String?, sound: String?, desktop: Bool? }
        var dismissal: String, timeoutSeconds: Double, desktop: String, sound: String
        var sounds: NotificationSoundPreferences.Wire, quietHours: Hours?
        var suppressWhileTypingSeconds: Double, dockBounce: String, sources: [String: Source]

        init(_ prefs: NotificationPreferences) {
            dismissal = prefs.dismissal.rawValue
            timeoutSeconds = prefs.timeoutSeconds
            desktop = prefs.desktop.rawValue
            sound = prefs.sound
            sounds = NotificationSoundPreferences.Wire(prefs.sounds)
            quietHours = prefs.quietHours.map { Hours(start: $0.start, end: $0.end) }
            suppressWhileTypingSeconds = prefs.suppressWhileTypingSeconds
            dockBounce = prefs.dockBounce.rawValue
            sources = Dictionary(uniqueKeysWithValues: prefs.sources.map { source, overrides in
                (source.rawValue, Source(dismissal: overrides.dismissal?.rawValue, sound: overrides.sound, desktop: overrides.desktop))
            })
        }
    }
}
