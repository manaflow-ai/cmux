import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// MDM managed preferences and team policy in the config layer
/// (spec/enterprise.md 4.4 and 5.2): precedence, write refusal on every
/// write path, readers, and reload when a profile changes.
@MainActor
@Suite struct ManagedPreferencesTests {
    static let speed = "ui.animationSpeed"

    func file(_ text: String) -> JSONValue { (try? JSONC.parse(text)) ?? .object([:]) }

    // MARK: Precedence (pure merge)

    /// Each row adds one layer; the highest present layer decides.
    @Test(arguments: [
        // (file, recommended, teamDefault, teamEnforced, forced, expected, managedBy)
        (nil, nil, nil, nil, nil, nil, nil),
        (nil, nil, "normal", nil, nil, "normal", nil),
        (nil, "off", "normal", nil, nil, "off", nil),
        ("fast", "off", "normal", nil, nil, "fast", nil),
        ("fast", "off", "normal", "normal", nil, "normal", "team"),
        ("fast", "off", "normal", "normal", "off", "off", "device"),
        (nil, nil, nil, nil, "normal", "normal", "device"),
    ] as [(String?, String?, String?, String?, String?, String?, String?)])
    func precedence(row: (String?, String?, String?, String?, String?, String?, String?)) {
        let (mine, recommended, teamDefault, teamEnforced, forced, expected, managedBy) = row
        let root = mine.map { file("{\"ui\": {\"animationSpeed\": \"\($0)\"}}") } ?? file("{}")
        var managed = ManagedPreferences()
        if let recommended { managed.recommended[Self.speed] = .string(recommended) }
        if let forced { managed.forced[Self.speed] = .string(forced) }
        var team = TeamPolicyLayer(teamName: "Acme")
        if let teamDefault { team.defaults[Self.speed] = .string(teamDefault) }
        if let teamEnforced { team.enforced[Self.speed] = .string(teamEnforced) }

        let result = EffectiveSettings.merge(file: root, managed: managed, team: team)

        #expect(result.root.value(at: ["ui", "animationSpeed"])?.stringValue == expected)
        #expect(result.fileRoot == root)
        switch managedBy {
        case "device": #expect(result.managedKeys[Self.speed] == .device)
        case "team": #expect(result.managedKeys[Self.speed] == .team("Acme"))
        default: #expect(result.managedKeys.isEmpty)
        }
        let overridden = mine != nil && managedBy != nil && mine != expected
        #expect(result.diagnostics.contains { $0.kind == .managedOverride && $0.path == Self.speed } == overridden)
    }

    @Test func policyKeysStayOutOfTheSettingsDocument() {
        let managed = ManagedPreferences(forced: ["EnrollmentToken": "tok", "DisabledFeatures": .array(["mcp"])], recommended: ["UpdateChannel": "nightly"])
        let result = EffectiveSettings.merge(file: file("{\"a\": 1}"), managed: managed, team: .none)
        #expect(result.root == file("{\"a\": 1}"))
        // Policy keys come from forced values only: a local user can write non-forced values.
        #expect(result.policy == ["EnrollmentToken": "tok", "DisabledFeatures": .array(["mcp"])])
        #expect(result.managedKeys.isEmpty)
    }

    @Test func forcedKeyReplacesANonObjectOnItsPath() {
        let result = EffectiveSettings.merge(file: file("{\"ui\": 3}"), managed: ManagedPreferences(forced: [Self.speed: "off"]), team: .none)
        #expect(result.root.value(at: ["ui", "animationSpeed"]) == "off")
    }

    // MARK: Readers

    @Test func plistReaderSplitsForcedAndRecommendedAndKeepsTypes() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "cmux-managed-\(UUID().uuidString).plist")
        let plist: [String: Any] = [Self.speed: "off", "layout.panePadding": 8, "RestrictToManagedTeam": true, "Recommended": ["layout.stripScrollbar": "auto"]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        let read = PlistManagedPreferenceReader(url: url).read()
        #expect(read.forced == [Self.speed: "off", "layout.panePadding": 8, "RestrictToManagedTeam": true])
        #expect(read.recommended == ["layout.stripScrollbar": "auto"])
        #expect(PlistManagedPreferenceReader(url: url.appending(path: "missing")).read() == .empty)
    }

    @Test func releaseBuildsIgnoreTheFileOverrideOnlyInRelease() {
        let reader = ManagedPreferenceLocation.defaultReader(environment: [ManagedPreferences.fileOverrideKey: "/tmp/x.plist"])
        #if DEBUG
        #expect(reader is PlistManagedPreferenceReader)
        #else
        #expect(reader is CFManagedPreferenceReader)
        #endif
        #expect(ManagedPreferenceLocation.defaultReader(environment: [:]) is CFManagedPreferenceReader)
        let watched = ManagedPreferenceLocation.watchedFiles(userName: "alice", environment: [:]).map(\.path)
        #expect(watched.contains("/Library/Managed Preferences/com.manaflow.cmux.plist"))
        #expect(watched.contains("/Library/Managed Preferences/alice/com.manaflow.cmux.plist"))
    }

    // MARK: Controller and write paths

    func controller(_ text: String, managed: ManagedPreferences) throws -> (SettingsController, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-managed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(text.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(managed), managedWatchFiles: [])
        return (settings, url)
    }

    @Test func forcedValueAppliesAndEveryWritePathRefusesIt() async throws {
        let (settings, url) = try controller("{\"ui\": {\"animationSpeed\": \"fast\"}}", managed: ManagedPreferences(forced: [Self.speed: "off"]))
        await settings.reload()
        #expect(settings.snapshot.animationSpeed == .off)
        #expect(settings.managedKeys == [Self.speed: .device])
        #expect(settings.fileRoot.value(at: ["ui", "animationSpeed"]) == "fast")

        let descriptor = try #require(SettingsSchema.descriptor(for: ["ui", "animationSpeed"]))
        await #expect(throws: SettingManaged(key: Self.speed, source: .device)) { try await settings.setSetting(descriptor, to: "normal", by: .user) }
        // The control socket's settings.set writes through the file directly; the same guard refuses it.
        await #expect(throws: SettingManaged.self) { try await settings.file.set("normal", at: ["ui", "animationSpeed"]) }
        await #expect(throws: SettingManaged.self) { try await settings.file.set(.object(["animationSpeed": "normal"]), at: ["ui"]) }
        await #expect(throws: SettingManaged.self) { try await settings.file.remove(["ui", "animationSpeed"]) }
        await #expect(throws: SettingManaged.self) { try await settings.file.apply([(path: ["ui", "animationSpeed"], value: nil)]) }
        // Unmanaged neighbors stay writable.
        try await settings.file.set("auto", at: ["layout", "stripScrollbar"])
        try await settings.resetAllSettings(by: .user)
        let after = try JSONC.parse(String(contentsOf: url, encoding: .utf8))
        #expect(after.value(at: ["ui", "animationSpeed"]) == "fast")
        #expect(after.value(at: ["layout", "stripScrollbar"]) == nil)
    }

    @Test func teamPolicyLayerAppliesAndManagesKeys() async throws {
        let (settings, _) = try controller("{}", managed: .empty)
        await settings.reload()
        settings.setTeamPolicy(TeamPolicyLayer(teamName: "Acme", enforced: [Self.speed: "normal"]))
        await settings.waitForLoad(atLeast: settings.loadCount + 1)
        #expect(settings.snapshot.animationSpeed == .normal)
        #expect(settings.managedKeys == [Self.speed: .team("Acme")])
        let descriptor = try #require(SettingsSchema.descriptor(for: ["ui", "animationSpeed"]))
        await #expect(throws: SettingManaged(key: Self.speed, source: .team("Acme"))) { try await settings.setSetting(descriptor, to: "off", by: .user) }
    }

    /// The wiring from the managed-profile watcher to a reload. Watcher
    /// latency has its own 1 s bound (ConfigFileWatcherTests); this test's
    /// duration is mostly main-actor hops, which take a minute or more under
    /// the full package run (a test here without a watcher took 55 s there),
    /// so its limit only catches a reload that never comes.
    @Test(.timeLimit(.minutes(5))) func aProfileChangeReloadsThroughTheFileWatcher() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-managed-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: configURL)
        // The profile file does not exist yet: the watcher waits on its directory.
        let profile = directory.appending(path: "profiles").appending(path: "com.manaflow.cmux.plist")
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: configURL,
                                          managedReader: PlistManagedPreferenceReader(url: profile), managedWatchFiles: [profile])
        settings.start()
        defer { settings.stop() }
        await settings.waitForLoad(atLeast: 1)
        #expect(settings.managedKeys.isEmpty)

        try FileManager.default.createDirectory(at: profile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [Self.speed: "off"], format: .xml, options: 0).write(to: profile, options: .atomic)
        // waitForLoad returns at once when the test is cancelled (time limit):
        // stop then, or this loop spins on the main actor and starves every
        // other main-actor test in the process.
        while settings.managedKeys.isEmpty, !Task.isCancelled {
            await settings.waitForLoad(atLeast: settings.loadCount + 1)
        }
        try #require(!settings.managedKeys.isEmpty, "the profile change never reloaded the settings")
        #expect(settings.snapshot.animationSpeed == .off)
    }

    // MARK: Team device policy and enrollment

    @Test func devicePolicyBecomesATeamLayerOnlyWhenManaged() {
        let managed: JSONValue = .object([
            "managed": true, "team": "team_00000000000000000001", "team_name": "Acme", "version": 3,
            "defaults": .object(["layout.stripScrollbar": "always"]),
            "enforced": .object([Self.speed: "off", "telemetry.level": "crash_only", "NotASetting": true]),
        ])
        #expect(TeamPolicyLayer(devicePolicy: managed) == TeamPolicyLayer(teamName: "Acme", defaults: ["layout.stripScrollbar": "always"], enforced: [Self.speed: "off"],
                                                                   teamID: "team_00000000000000000001", version: 3))
        #expect(TeamPolicyLayer(devicePolicy: .object(["managed": false, "enforced": .object(["telemetry.level": "off"])])) == nil)
    }

    /// Shared vector with backend/apps/api/test/team-enrollment.test.ts.
    @Test func enrollmentTokenHashMatchesTheBackendVector() {
        #expect(ManagedPreferences.enrollmentTokenHash("cmxe_shared_vector_v1") == "gBhFw31wF2LFrvU2l8Xgno2GFgrlOQQkj_hhy9_5fvw")
        #expect(ManagedPreferences(forced: ["EnrollmentToken": "  tok \n"]).enrollmentToken == "tok")
        #expect(ManagedPreferences(recommended: ["EnrollmentToken": ""]).enrollmentToken == nil)
    }

    // MARK: Status file (MDM tooling)

    @Test func statusReportListsKeysSourcesAndConflictsButNeverTheToken() {
        let managed = ManagedPreferences(forced: [Self.speed: "off", "EnrollmentToken": "cmxe_secret", "DisabledFeatures": .array(["mcp"])],
                                         recommended: ["layout.stripScrollbar": "always"])
        let team = TeamPolicyLayer(teamName: "Acme", enforced: [Self.speed: "normal", "appearance.borders": "none"], teamID: "team_00000000000000000001", version: 4)
        let effective = EffectiveSettings.merge(file: file("{}"), managed: managed, team: team)
        let body = ManagedStatusReport.body(context: .init(appVersion: "1.2.3", bundleID: "com.cmuxterm.app"), managed: managed, team: team, effective: effective)
        #expect(!body.compactText.contains("cmxe_secret"))
        #expect(body["enrollment_token_present"] == true)
        #expect(body["policy"]?["EnrollmentToken"] == "<set>")
        #expect(body["policy"]?["DisabledFeatures"] == .array(["mcp"]))
        #expect(body["keys_forced"] == .array(["DisabledFeatures", "EnrollmentToken", "ui.animationSpeed"]))
        #expect(body["applied"] == .array([
            .object(["key": "appearance.borders", "source": "team", "value": "none"]),
            .object(["key": "ui.animationSpeed", "source": "mdm", "value": "off"]),
        ]))
        #expect(body["conflicts"] == .array([.object(["key": .string(Self.speed), "mdm_value": "off", "team_value": "normal", "winner": "mdm"])]))
        #expect(body["managing_team"]?["policy_version"] == 4)
    }

    @Test(.timeLimit(.minutes(1))) func controllerWritesTheStatusFileOnlyWhenItChanges() async throws {
        let (settings, _) = try controller("{}", managed: ManagedPreferences(forced: [Self.speed: "off"]))
        let url = FileManager.default.temporaryDirectory.appending(path: "cmux-status-\(UUID().uuidString)/managed-status.json")
        settings.writeManagedStatus(to: url, context: .init(appVersion: "1", bundleID: "com.cmuxterm.app.debug"))
        await settings.reload()
        while !FileManager.default.fileExists(atPath: url.path) { await Task.yield() }
        var written = try JSONValue.parse(Data(contentsOf: url))
        while written["applied"] == nil { await Task.yield(); written = try JSONValue.parse(Data(contentsOf: url)) }
        #expect(written["applied"]?.arrayValue?.count == 1)
        let stamp = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        await settings.reload()
        await settings.reload()
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == stamp)
        #expect(ManagedStatusReport.defaultURL(bundleID: "com.cmuxterm.app", home: URL(fileURLWithPath: "/Users/a")).path == "/Users/a/Library/Application Support/cmux/managed-status.json")
    }

    // MARK: Review findings (2026-10-02)

    @Test func anUnreadableFileStillAppliesForcedValuesOverTheLastGoodFile() async throws {
        let (settings, url) = try controller("{\"layout\": {\"stripScrollbar\": \"always\"}}", managed: ManagedPreferences(forced: [Self.speed: "off"]))
        await settings.reload()
        try Data("{ not json".utf8).write(to: url)
        await settings.reload()
        #expect(settings.snapshot.animationSpeed == .off)
        #expect(settings.snapshot.stripScrollbar == .always)
        #expect(settings.managedKeys == [Self.speed: .device])
        #expect(settings.diagnostics.contains { $0.kind == .unreadableFile })
        // Broken from the start: forced values apply over an empty document.
        let (fresh, freshURL) = try controller("{ broken", managed: ManagedPreferences(forced: [Self.speed: "off"]))
        await fresh.reload()
        #expect(fresh.snapshot.animationSpeed == .off)
        _ = freshURL
    }

    @Test func policyKeysAndTheEnrollmentTokenIgnoreNonForcedValues() {
        let local = ManagedPreferences(recommended: ["EnrollmentToken": "planted", "DisabledFeatures": .array(["mcp"])])
        #expect(local.enrollmentToken == nil)
        #expect(EffectiveSettings.merge(file: file("{}"), managed: local, team: .none).policy.isEmpty)
    }

    @Test func anMDMValueThatOverridesTheTeamPolicyIsReported() {
        let result = EffectiveSettings.merge(file: file("{}"), managed: ManagedPreferences(forced: [Self.speed: "off"]),
                                             team: TeamPolicyLayer(teamName: "Acme", enforced: [Self.speed: "normal"]))
        #expect(result.root.value(at: ["ui", "animationSpeed"]) == "off")
        #expect(result.diagnostics.contains { $0.kind == .managedConflict && $0.path == Self.speed })
    }

    @Test func theTeamLayerSetsOnlyCatalogSettings() {
        let team = TeamPolicyLayer(teamName: "Acme", enforced: [
            "appearance": .object(["borders": "none"]), "shortcuts.bindings.tab.close": "cmd+w", "actions.evil": .object(["command": "rm"]),
            Self.speed: "normal",
        ])
        let result = EffectiveSettings.merge(file: file("{\"appearance\": {\"density\": \"comfortable\"}}"), managed: .empty, team: team)
        #expect(result.root.value(at: ["appearance", "density"]) == "comfortable")
        #expect(result.root["shortcuts"] == nil)
        #expect(result.root["actions"] == nil)
        #expect(result.managedKeys == [Self.speed: .team("Acme")])
    }

    /// The backend's team.device.policy shape reaches a real setting (effect, not just the layer).
    @Test func backendDevicePolicyChangesAnEffectiveSetting() async throws {
        let (settings, _) = try controller("{}", managed: .empty)
        await settings.reload()
        let read: JSONValue = .object([
            "team": "team_00000000000000000001", "managed": true, "team_name": "Acme", "version": 2,
            "defaults": .object([:]), "enforced": .object([Self.speed: "off", "telemetry.level": "off"]),
        ])
        let layer = try #require(TeamPolicyLayer(devicePolicy: read))
        #expect(layer.enforced.keys.sorted() == [Self.speed])
        settings.setTeamPolicy(layer)
        await settings.waitForLoad(atLeast: settings.loadCount + 1)
        #expect(settings.snapshot.animationSpeed == .off)
        // A stale read (older version of the same team) does not roll back.
        settings.setTeamPolicy(TeamPolicyLayer(teamName: "Acme", enforced: [Self.speed: "normal"], teamID: "team_00000000000000000001", version: 1))
        #expect(settings.teamPolicy.version == 2)
    }
}
