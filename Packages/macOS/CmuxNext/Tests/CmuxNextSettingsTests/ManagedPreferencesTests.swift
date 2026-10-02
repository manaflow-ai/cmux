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
        #expect(result.policy == ["EnrollmentToken": "tok", "DisabledFeatures": .array(["mcp"]), "UpdateChannel": "nightly"])
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
        await #expect(throws: SettingManaged(key: Self.speed, source: .device)) { try await settings.setSetting(descriptor, to: "normal") }
        // The control socket's settings.set writes through the file directly; the same guard refuses it.
        await #expect(throws: SettingManaged.self) { try await settings.file.set("normal", at: ["ui", "animationSpeed"]) }
        await #expect(throws: SettingManaged.self) { try await settings.file.set(.object(["animationSpeed": "normal"]), at: ["ui"]) }
        await #expect(throws: SettingManaged.self) { try await settings.file.remove(["ui", "animationSpeed"]) }
        await #expect(throws: SettingManaged.self) { try await settings.file.apply([(path: ["ui", "animationSpeed"], value: nil)]) }
        // Unmanaged neighbors stay writable.
        try await settings.file.set("auto", at: ["layout", "stripScrollbar"])
        try await settings.resetAllSettings()
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
        await #expect(throws: SettingManaged(key: Self.speed, source: .team("Acme"))) { try await settings.setSetting(descriptor, to: "off") }
    }

    @Test(.timeLimit(.minutes(1))) func aProfileChangeReloadsThroughTheFileWatcher() async throws {
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
        while settings.managedKeys.isEmpty {
            await settings.waitForLoad(atLeast: settings.loadCount + 1)
        }
        #expect(settings.snapshot.animationSpeed == .off)
    }
}
