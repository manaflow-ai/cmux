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
}
