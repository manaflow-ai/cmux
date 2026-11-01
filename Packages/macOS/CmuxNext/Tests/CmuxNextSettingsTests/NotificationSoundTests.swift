import CmuxNextSettings
import Testing

/// Notification sounds per event and per level (user, 2026-10-26: "make it possible to change
/// notification sounds, make it super customizable per workspace, group, etc"). Levels: an agent
/// kind, a workspace, its groups (innermost first), then the global per-event sound, then
/// `notifications.sound`. Each level inherits, picks a sound or mutes with "none".
struct NotificationSoundTests {
    private static func snapshot(_ sounds: JSONValue, sound: JSONValue = "Glass") -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(["notifications": ["sound": sound, "sounds": sounds]], validDensities: [], validMetrics: [])
    }

    private static let scope = NotificationSoundScope(
        agent: "Codex", workspace: "ws_1",
        groups: [.init(id: "grp_inner", name: "Inner"), .init(id: "grp_outer", name: "Agents & routing")]
    )

    // MARK: Events

    @Test(arguments: [
        (NotificationSource.agent, NotificationSoundEvent.Level.info, NotificationSoundEvent.finished),
        (.agent, .warning, .needsInput),
        (.agent, .error, .error),
        (.terminal, .info, .bell),
        (.terminal, .error, .error),
        (.cli, .info, .message),
        (.cli, .warning, .needsInput),
    ])
    func eachNotificationHasAnEvent(_ source: NotificationSource, _ level: NotificationSoundEvent.Level, _ event: NotificationSoundEvent) {
        #expect(NotificationSoundEvent(source: source, level: level) == event)
    }

    // MARK: Parsing

    @Test func soundsParseFromCmuxJSON() {
        let snapshot = Self.snapshot([
            "volume": 0.8, "when": "whenInactive", "cooldownSeconds": 3,
            "events": ["needsInput": "Ping", "error": "Basso"],
            "groups": ["Agents & routing": ["sound": "Submarine", "volume": 0.5]],
            "workspaces": ["ws_1": "none"],
            "agents": ["codex": ["events": ["finished": "Hero"]]],
        ])
        let sounds = snapshot.notifications.sounds
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
        #expect(sounds.volume == 0.8)
        #expect(sounds.when == .whenInactive)
        #expect(sounds.cooldownSeconds == 3)
        #expect(sounds.events == [.needsInput: "Ping", .error: "Basso"])
        #expect(sounds.groups["Agents & routing"] == NotificationSoundRule(sound: "Submarine", volume: 0.5))
        #expect(sounds.workspaces["ws_1"] == NotificationSoundRule(sound: "none"))
        #expect(sounds.agents["codex"] == NotificationSoundRule(events: [.finished: "Hero"]))
    }

    @Test func aBadValueKeepsItsDefaultWithADiagnostic() {
        let snapshot = Self.snapshot([
            "volume": "loud", "when": "sometimes",
            "events": ["ringing": "Ping"],
            "workspaces": ["ws_1": 3, "ws_2": ["sound": "Pop", "volume": 4]],
        ])
        let sounds = snapshot.notifications.sounds
        #expect(sounds.volume == 1)
        #expect(sounds.when == .unlessViewed)
        #expect(sounds.events.isEmpty)
        #expect(sounds.workspaces["ws_1"] == nil)
        #expect(sounds.workspaces["ws_2"] == NotificationSoundRule(sound: "Pop", volume: 1), "an out-of-range volume clamps")
        let paths = Set(snapshot.diagnostics.map(\.path))
        #expect(paths.isSuperset(of: ["notifications.sounds.volume", "notifications.sounds.when", "notifications.sounds.events.ringing",
                                      "notifications.sounds.workspaces.ws_1", "notifications.sounds.workspaces.ws_2"]), "\(paths)")
    }

    @Test func aRuleRoundTripsThroughItsJSON() {
        let rule = NotificationSoundRule(sound: "Glass", volume: 0.25, events: [.needsInput: "Ping"])
        var problems: [String] = []
        #expect(NotificationSoundRule.parse(rule.json, problems: &problems) == rule)
        #expect(problems.isEmpty)
        #expect(NotificationSoundRule.accepts(rule.json))
        #expect(!NotificationSoundRule.accepts(["sound": 3]))
    }

    // MARK: Inheritance

    @Test func withNoLevelsTheGlobalSoundPlays() {
        let sounds = NotificationSoundPreferences()
        #expect(sounds.choice(for: .finished, in: Self.scope, fallback: "Glass") == NotificationSoundChoice(name: "Glass", volume: 1, level: "global"))
    }

    @Test func anEventsGlobalSoundBeatsTheDefaultSound() {
        var sounds = NotificationSoundPreferences()
        sounds.events[.needsInput] = "Ping"
        #expect(sounds.choice(for: .needsInput, in: Self.scope, fallback: "Glass")?.name == "Ping")
        #expect(sounds.choice(for: .finished, in: Self.scope, fallback: "Glass")?.name == "Glass")
    }

    @Test func theMostSpecificLevelWins() {
        var sounds = NotificationSoundPreferences()
        sounds.events[.finished] = "Pop"
        sounds.groups["Agents & routing"] = NotificationSoundRule(sound: "Submarine")
        #expect(sounds.choice(for: .finished, in: Self.scope, fallback: "Glass")?.name == "Submarine", "a group (by name) beats the global event sound")
        sounds.groups["grp_inner"] = NotificationSoundRule(sound: "Tink")
        #expect(sounds.choice(for: .finished, in: Self.scope, fallback: "Glass")?.name == "Tink", "an inner group beats its outer group")
        sounds.workspaces["ws_1"] = NotificationSoundRule(sound: "Frog")
        #expect(sounds.choice(for: .finished, in: Self.scope, fallback: "Glass")?.name == "Frog", "a workspace beats its groups")
        sounds.agents["codex"] = NotificationSoundRule(events: [.finished: "Hero"])
        #expect(sounds.choice(for: .finished, in: Self.scope, fallback: "Glass")?.name == "Hero", "an agent kind beats its workspace")
        #expect(sounds.choice(for: .needsInput, in: Self.scope, fallback: "Glass")?.name == "Frog", "the agent sets only finished; needsInput inherits")
    }

    @Test func noneMutesALevelButAMoreSpecificLevelStillPlays() {
        var sounds = NotificationSoundPreferences()
        sounds.groups["grp_outer"] = NotificationSoundRule(sound: "none")
        #expect(sounds.choice(for: .finished, in: Self.scope, fallback: "Glass") == nil)
        sounds.workspaces["ws_1"] = NotificationSoundRule(events: [.needsInput: "Ping"])
        #expect(sounds.choice(for: .needsInput, in: Self.scope, fallback: "Glass")?.name == "Ping")
        #expect(sounds.choice(for: .finished, in: Self.scope, fallback: "Glass") == nil)
    }

    @Test func volumeIsTheNearestLevelsShareOfTheMaster() {
        var sounds = NotificationSoundPreferences()
        sounds.volume = 0.5
        #expect(sounds.choice(for: .finished, in: Self.scope, fallback: "Glass")?.volume == 0.5)
        sounds.groups["grp_outer"] = NotificationSoundRule(volume: 0.5)
        #expect(sounds.choice(for: .finished, in: Self.scope, fallback: "Glass")?.volume == 0.25)
        sounds.workspaces["ws_1"] = NotificationSoundRule(volume: 1)
        #expect(sounds.choice(for: .finished, in: Self.scope, fallback: "Glass")?.volume == 0.5)
    }

    // MARK: Policy

    private static func decide(_ prefs: NotificationPreferences, viewed: Bool = false, active: Bool = true,
                               event: NotificationSoundEvent? = nil) -> NotificationPolicy.Decision {
        var arrival = NotificationPolicy.Arrival(source: .agent)
        arrival.paneIsViewed = viewed
        arrival.appActive = active
        arrival.soundEvent = event
        arrival.soundScope = scope
        return NotificationPolicy(prefs: prefs).decide(arrival)
    }

    @Test func theDecisionCarriesTheScopesSoundAndVolume() {
        var prefs = NotificationPreferences()
        prefs.sounds.workspaces["ws_1"] = NotificationSoundRule(sound: "Frog", volume: 0.4)
        let decision = Self.decide(prefs, event: .needsInput)
        #expect(decision.sound == "Frog")
        #expect(decision.soundVolume == 0.4)
    }

    @Test func timingDecidesWhetherAViewedPaneOrAnActiveAppSounds() {
        var prefs = NotificationPreferences()
        #expect(Self.decide(prefs, viewed: true).sound == nil, "unlessViewed (the default) keeps a viewed pane silent")
        #expect(Self.decide(prefs).sound == "default")
        prefs.sounds.when = .always
        #expect(Self.decide(prefs, viewed: true).sound == "default")
        prefs.sounds.when = .whenInactive
        #expect(Self.decide(prefs, active: true).sound == nil)
        #expect(Self.decide(prefs, active: false).sound == "default")
    }

    // MARK: Bursts

    @Test func aBurstSoundsOnceButAMoreUrgentEventStillPlays() {
        var throttle = NotificationSoundThrottle(cooldown: .seconds(1.5))
        let start = ContinuousClock.now
        let steps: [(NotificationSoundEvent, Int)] = [(.finished, 0), (.finished, 200), (.bell, 400), (.needsInput, 600), (.finished, 1_000), (.finished, 2_200)]
        var admitted: [Bool] = []
        for (event, ms) in steps { admitted.append(throttle.admit(event, at: start + .milliseconds(ms))) }
        // A second finish and a bell in the burst are silent; an agent asking still sounds; after the
        // cooldown a finish sounds again.
        #expect(admitted == [true, false, false, true, false, true])
    }

    @Test func aZeroCooldownNeverThrottles() {
        var throttle = NotificationSoundThrottle(cooldown: .zero)
        let start = ContinuousClock.now
        let first = throttle.admit(.finished, at: start), second = throttle.admit(.finished, at: start)
        #expect(first && second)
    }

    // MARK: Menu, palette and CLI edits

    @Test func anEditSetsInheritsOrClearsALevel() {
        var rule = NotificationSoundRule().applying(sound: "Glass", event: nil, volume: nil)
        #expect(rule == NotificationSoundRule(sound: "Glass"))
        rule = rule.applying(sound: "Ping", event: .needsInput, volume: 0.5)
        #expect(rule == NotificationSoundRule(sound: "Glass", volume: 0.5, events: [.needsInput: "Ping"]))
        #expect(rule.applying(sound: "inherit", event: .needsInput, volume: nil).events.isEmpty, "inherit for one event clears only it")
        let cleared = rule.applying(sound: "inherit", event: nil, volume: nil)
        #expect(cleared.sound == nil && cleared.events.isEmpty && cleared.volume == 0.5, "inherit for every event keeps only the volume")
        #expect(NotificationSoundRule().applying(sound: "inherit", event: nil, volume: nil).isEmpty)
        #expect(rule.applying(sound: nil, event: nil, volume: 7).volume == 1, "a volume clamps to 0...1")
    }

    // MARK: Schema

    @Test func everySoundSettingIsASchemaKeyAgentsMaySet() throws {
        for event in NotificationSoundEvent.allCases {
            let row = try #require(SettingsSchema.descriptor(for: ["notifications", "sounds", "events", event.rawValue]))
            #expect(row.kind == .sound)
            #expect(row.accepts("Ping"))
        }
        for key in ["groups", "workspaces", "agents"] {
            let row = try #require(SettingsSchema.descriptor(for: ["notifications", "sounds", key]))
            #expect(row.accepts(["ws_1": ["sound": "Glass", "volume": 0.5, "events": ["error": "Basso"]], "ws_2": "none"]))
            #expect(!row.accepts(["ws_1": ["sound": 3]]))
            #expect(!row.accepts("Glass"))
        }
        let volume = try #require(SettingsSchema.descriptor(for: ["notifications", "sounds", "volume"]))
        #expect(volume.accepts(0.3))
        #expect(!volume.accepts(2))
        #expect(SettingsSchema.descriptor(for: ["notifications", "sounds", "when"])?.accepts("whenInactive") == true)
        #expect(SettingsSchema.descriptor(for: ["notifications", "sounds", "cooldownSeconds"]) != nil)
    }
}
