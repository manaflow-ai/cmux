import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// A key the person never changed follows its default, also after a release changes the default
/// (Leo 2026-11-08: "if I'm on the defaults and the defaults get changed, that should reflect into
/// stuff"), and a key they set stays: a write of the default stores nothing, and the one-time launch
/// pass drops copies of the current or a former default already stored.
@MainActor @Suite(.serialized) struct StoredDefaultsTests {
    let home = FileManager.default.temporaryDirectory.appending(path: "cn-stored-defaults-\(UUID().uuidString)")
    var url: URL { home.appending(path: "cmux-next.json") }

    func controller(_ text: String, managed: ManagedPreferences = ManagedPreferences()) async throws -> SettingsController {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(managed), managedWatchFiles: [])
        await settings.reload()
        return settings
    }

    func marker() throws -> UserDefaults {
        let suite = "cn-stored-defaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func writingTheDefaultStoresNothing() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = try await controller(#"{ "appearance": { "chromeStyle": "card" } }"#)
        let style = try #require(SettingsSchema.descriptor(for: ChromeStyleSetting.configPath))

        try await settings.setSetting(style, to: .string(ChromeStyleSetting.fallback.rawValue), by: .user)
        #expect(try await settings.file.value(at: ChromeStyleSetting.configPath) == nil)
        #expect(try await settings.file.value(at: ["appearance"]) == nil, "the emptied object goes too")
        #expect(settings.snapshot.chromeStyle == ChromeStyleSetting.fallback)

        try await settings.setSetting(style, to: .string(ChromeStyle.card.rawValue), by: .user)
        #expect(try await settings.file.value(at: ChromeStyleSetting.configPath) == .string("card"))
    }

    /// MDM recommends another style, which fills the key when the file leaves it out, so only a
    /// stored default keeps the person's pick.
    @Test func aRecommendedValueKeepsAnExplicitDefault() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = try await controller("{}", managed: ManagedPreferences(recommended: ["appearance.chromeStyle": .string("card")]))
        let style = try #require(SettingsSchema.descriptor(for: ChromeStyleSetting.configPath))

        try await settings.setSetting(style, to: .string(ChromeStyleSetting.fallback.rawValue), by: .user)
        #expect(try await settings.file.value(at: ChromeStyleSetting.configPath) == .string(ChromeStyleSetting.fallback.rawValue))
    }

    /// Writes `descriptor`'s default and returns what the file then holds at its path.
    func writingTheDefault(_ path: [String], in settings: SettingsController) async throws -> JSONValue? {
        let descriptor = try #require(SettingsSchema.descriptor(for: path))
        try await settings.setSetting(descriptor, to: descriptor.defaultValue, by: .user)
        return try await settings.file.value(at: path)
    }

    /// The team's default fills the key when the file leaves it out.
    @Test func aTeamDefaultKeepsAnExplicitDefault() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = try await controller("{}")
        settings.setTeamPolicy(TeamPolicyLayer(teamName: "Acme", defaults: ["appearance.chromeStyle": .string("card")]))
        await settings.reload()
        #expect(try await writingTheDefault(ChromeStyleSetting.configPath, in: settings) == .string(ChromeStyleSetting.fallback.rawValue))
    }

    /// A team default under an older name (`EffectiveSettings.legacyKeys`) fills the new key too.
    @Test func aTeamDefaultUnderAnOlderNameKeepsAnExplicitDefault() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = try await controller("{}")
        let old = AgentPaneDisplaySettingsSchema.legacySessionInfoPlacementPath.joined(separator: ".")
        settings.setTeamPolicy(TeamPolicyLayer(teamName: "Acme", defaults: [old: .string("push")]))
        await settings.reload()
        let path = AgentPaneDisplaySettingsSchema.sessionInfoPlacementPath
        #expect(try await writingTheDefault(path, in: settings) == .string(AgentPaneDisplaySettingsSchema.sessionInfoPlacementDefault))
    }

    /// Another editor's settings fill the code editor's keys (`editor.importFrom`, "auto" by default):
    /// VS Code's `editor.wordWrap: "on"` applies unless cmux-next.json says otherwise.
    @Test func anImportedEditorValueKeepsAnExplicitDefault() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = try await controller(#"{ "editor": { "wordWrap": "on" } }"#)
        #expect(try await writingTheDefault(EditorSettingsSchema.wordWrapPath, in: settings) == .string(EditorSettingsSchema.wordWrapDefault))
    }

    /// With no editor import, the built-in per-language values still fill an unset key (Markdown
    /// wraps), so Word Wrap Off stays stored.
    @Test func aLanguageDefaultKeepsAnExplicitDefault() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = try await controller(#"{ "editor": { "importFrom": "none", "wordWrap": "on" } }"#)
        #expect(try await writingTheDefault(EditorSettingsSchema.wordWrapPath, in: settings) == .string(EditorSettingsSchema.wordWrapDefault))
    }

    /// `editor.autoClosingQuotes` follows `editor.autoClosingBrackets` when unset.
    @Test func aKeyThatFollowsAnotherKeepsAnExplicitDefault() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = try await controller(#"{ "editor": { "importFrom": "none", "autoClosingBrackets": false } }"#)
        #expect(try await writingTheDefault(EditorSettingsSchema.autoClosingQuotesPath, in: settings)
            == .bool(EditorSettingsSchema.autoClosingQuotesDefault))
    }

    /// An older file's `browser.openTerminalLinksInCmuxBrowser` fills `browser.openLinksInCmuxBrowser`.
    @Test func anOlderKeyInTheFileKeepsAnExplicitDefault() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = try await controller(#"{ "browser": { "openTerminalLinksInCmuxBrowser": false } }"#)
        #expect(try await writingTheDefault(LinkRouting.openPath, in: settings) == .bool(LinkRouting.openDefault))
    }

    /// With no older key and no lower layer, the browser key and the editor import's own selector
    /// follow their defaults like any other (#38167 F1, F2).
    @Test func withNothingBelowTheDefaultIsRemoved() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = try await controller("{}")
        #expect(try await writingTheDefault(LinkRouting.openPath, in: settings) == nil)
        #expect(try await writingTheDefault(EditorSettingsSchema.importFromPath, in: settings) == nil)
    }

    /// The Debug tunable `agent.harnessPlacement` fills `agentPane.display.harnessPlacement`.
    @Test func aDebugTunableKeepsAnExplicitDefault() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = try await controller("{}")
        #expect(try await writingTheDefault(AgentPaneDisplaySettingsSchema.harnessPlacementPath, in: settings)
            == .string(AgentPaneDisplaySettingsSchema.harnessPlacementDefault))
    }

    /// Every entry of `unsetIsNotDefaultKeys` names a schema key or a prefix of one.
    @Test func everyFallbackEntryNamesSchemaKeys() {
        for key in SettingsSchema.unsetIsNotDefaultKeys.keys {
            #expect(SettingsSchema.all.contains { key.hasSuffix(".") ? $0.id.hasPrefix(key) : $0.id == key }, "\(key)")
        }
    }

    /// The default changed from "flat-sidebar-line" (stored by an old pick of the row's default) to
    /// the current one: the stored copy goes and the key follows the new default; a copy of the
    /// current default goes too; the theme, the background and a value that was never a default stay.
    @Test func theLaunchPassDropsStoredDefaultsOnce() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let text = """
        {
          "appearance": { "chromeStyle": "flat-sidebar-line", "theme": "Catppuccin Mocha", "backgroundOpacity": 0.9 },
          "diff": { "layout": "auto" },
          "workspaces": { "newPlacement": "bottom" }
        }
        """
        let settings = try await controller(text)
        let marker = try marker()
        let former: [String: [JSONValue]] = ["appearance.chromeStyle": [.string("flat-sidebar-line")]]

        let report = try #require(try await settings.forgetStoredDefaults(marker: marker, formerDefaults: former))
        #expect(report.dropped == ["appearance.chromeStyle": .string("flat-sidebar-line"), "diff.layout": .string("auto")])
        #expect(report.kept["appearance.theme"] == .string("Catppuccin Mocha"))
        #expect(report.kept["workspaces.newPlacement"] == .string("bottom"))

        #expect(try await settings.file.value(at: ChromeStyleSetting.configPath) == nil)
        #expect(settings.snapshot.chromeStyle == ChromeStyleSetting.fallback, "the unset key follows the current default")
        #expect(try await settings.file.value(at: ["diff"]) == nil)
        #expect(try await settings.file.value(at: ["appearance", "theme"]) == .string("Catppuccin Mocha"))
        #expect(try await settings.file.value(at: ["appearance", "backgroundOpacity"]) == .number(0.9))
        #expect(try await settings.file.value(at: ["workspaces", "newPlacement"]) == .string("bottom"))

        // The record beside the file keeps the old text, so nothing is lost.
        let record = try JSONC.parse(String(contentsOf: home.appending(path: "cmux-next.json.defaults-forgotten.json"), encoding: .utf8))
        #expect(record.value(at: ["before"]) == .string(text))

        // Once: a later pick of the former default is the person's and stays.
        try await settings.file.set(.string("flat-sidebar-line"), at: ChromeStyleSetting.configPath)
        #expect(try await settings.forgetStoredDefaults(marker: marker, formerDefaults: former) == nil)
        #expect(try await settings.file.value(at: ChromeStyleSetting.configPath) == .string("flat-sidebar-line"))
    }

    /// cmux-next.json is one file for every build on the Mac (NIGHTLY, RC, each tagged DEV build), and
    /// each build has its own UserDefaults. The pass runs once per file: a build that launches later
    /// on the same file leaves the person's pick of a former default alone. It ran once per build, so
    /// every fresh DEV build dropped `updates.downloadAutomatically: true` (a former default) from the
    /// shared file and the running NIGHTLY's updater flipped from on to deferred two seconds after
    /// that build launched (NIGHTLY updater log, 2026-11-08T08:05:19.567Z DEV launch, 08:05:21.615Z
    /// "automatic downloads deferred (setting false ...)").
    @Test func thePassRunsOncePerFileNotOncePerBuild() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let nightly = try await controller(#"{ "diff": { "layout": "auto" } }"#)
        #expect(try await nightly.forgetStoredDefaults(marker: try marker()) != nil)

        // The person turns Automatic Updates on (it was the default once) after the pass.
        try await nightly.setSetting(at: UpdatesSettings.downloadAutomaticallyPath, to: .bool(true), by: .user)
        #expect(try await nightly.file.value(at: UpdatesSettings.downloadAutomaticallyPath) == .bool(true))

        // A DEV build launches on the same file with its own UserDefaults.
        let dev = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                     managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await dev.reload()
        let devMarker = try marker()
        #expect(try await dev.forgetStoredDefaults(marker: devMarker) == nil)
        #expect(devMarker.bool(forKey: SettingsController.storedDefaultsForgottenKey), "the build records it too")
        #expect(try await dev.file.value(at: UpdatesSettings.downloadAutomaticallyPath) == .bool(true))
    }

    /// A pass that found nothing to drop still counts as run for the file.
    @Test func aPassThatDroppedNothingStillRunsOncePerFile() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = try await controller(#"{ "workspaces": { "newPlacement": "bottom" } }"#)
        let report = try #require(try await settings.forgetStoredDefaults(marker: try marker()))
        #expect(report.dropped.isEmpty)

        try await settings.file.set(.bool(true), at: UpdatesSettings.downloadAutomaticallyPath)
        #expect(try await settings.forgetStoredDefaults(marker: try marker()) == nil)
        #expect(try await settings.file.value(at: UpdatesSettings.downloadAutomaticallyPath) == .bool(true))
    }

    /// A null the first builds of this change stored for a default write goes once; a set value stays.
    @Test func strayNullsGoOnce() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let text = #"{ "appearance": { "chromeStyle": null }, "diff": { "layout": "split" }, "notifications": { "quietHours": null } }"#
        let settings = try await controller(text)
        let marker = try marker()

        #expect(try await settings.dropStrayNulls(marker: marker) == ["appearance.chromeStyle"])
        #expect(try await settings.file.value(at: ["appearance"]) == nil)
        #expect(try await settings.file.value(at: ["diff", "layout"]) == .string("split"))
        #expect(try await settings.file.value(at: ["notifications", "quietHours"]) == .null, "null is Off there, on purpose")
        try await settings.file.set(.null, at: ChromeStyleSetting.configPath)
        #expect(try await settings.dropStrayNulls(marker: marker).isEmpty)
    }

    /// The passes read the file, then write it a few awaits later; a value someone set in between
    /// stays (the removal rechecks each path against the file as it is at the write).
    @Test func aValueSetSinceTheReadStays() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(#"{ "appearance": { "chromeStyle": "card", "theme": "Nord" }, "diff": { "layout": null } }"#.utf8).write(to: url)
        let file = CmuxConfigFile(url: url)

        let (removed, before) = try await file.removeUnchanged([
            (path: ["appearance", "chromeStyle"], value: .string(ChromeStyleSetting.fallback.rawValue)),
            (path: ["diff", "layout"], value: .null),
        ])
        #expect(removed == [["diff", "layout"]])
        #expect(before.contains("card"))
        #expect(try await file.value(at: ChromeStyleSetting.configPath) == .string("card"))
        #expect(try await file.value(at: ["diff"]) == nil, "the emptied object goes too")
        #expect(try await file.value(at: ["appearance", "theme"]) == .string("Nord"))
    }

    /// The record beside the file goes first: when it cannot be written, nothing is removed.
    @Test func aFailedRecordWriteLeavesTheFile() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let text = #"{ "diff": { "layout": "auto" } }"#
        let settings = try await controller(text)
        // A directory where the record goes, so its write fails.
        try FileManager.default.createDirectory(at: home.appending(path: "cmux-next.json.defaults-forgotten.json/x"),
                                                withIntermediateDirectories: true)

        await #expect(throws: (any Error).self) { try await settings.forgetStoredDefaults(marker: try marker(), formerDefaults: [:]) }
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }

    /// Every former default names a schema key and differs from its current default.
    @Test func formerDefaultsNameSchemaKeys() {
        for (key, values) in SettingsSchema.formerDefaults {
            let descriptor = SettingsSchema.descriptor(for: CmuxConfigFile.keyPath(from: key))
            #expect(descriptor != nil, "\(key)")
            #expect(!values.contains { $0 == descriptor?.defaultValue }, "\(key)")
        }
    }
}
