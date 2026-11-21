import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `appearance.font`: the whole app's font (Leo 2026-11-08: "there's no whole app font change
/// thing"). The default stays the macOS system font (ui-font-pin.json); a listed family is the
/// snapshot's `appFontFamily` (SettingsApplier gives it to `DesignSettings`), and an unlisted value falls back to the system font with a diagnostic.
@MainActor struct AppFontSettingTests {
    static func parse(_ object: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(object), validDensities: [], validMetrics: [])
    }

    @Test func theDefaultIsTheSystemFont() throws {
        #expect(Self.parse([:]).appFontFamily == nil)
        #expect(Self.parse(["appearance": .object(["font": .string("system")])]).appFontFamily == nil)
        let row = try #require(SettingsSchema.descriptor(for: AppFontSetting.configPath))
        #expect(row.defaultValue == .string("system"))
        #expect(row.isPaletteExposed)
    }

    @Test func aListedFamilyIsTheAppFont() {
        let snapshot = Self.parse(["appearance": .object(["font": .string("Avenir Next")])])
        #expect(snapshot.appFontFamily == "Avenir Next")
    }

    @Test func anUnlistedFamilyIsTheSystemFontWithADiagnostic() {
        let snapshot = Self.parse(["appearance": .object(["font": .string("Comic Sans MS")])])
        #expect(snapshot.appFontFamily == nil)
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.font" })
    }
}
