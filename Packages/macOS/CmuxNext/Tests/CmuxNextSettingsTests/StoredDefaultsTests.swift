import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
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
        let defaults = try #require(UserDefaults(suiteName: suite))
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

    /// Every former default names a schema key and differs from its current default.
    @Test func formerDefaultsNameSchemaKeys() {
        for (key, values) in SettingsSchema.formerDefaults {
            let descriptor = SettingsSchema.descriptor(for: CmuxConfigFile.keyPath(from: key))
            #expect(descriptor != nil, "\(key)")
            #expect(!values.contains { $0 == descriptor?.defaultValue }, "\(key)")
        }
    }
}
