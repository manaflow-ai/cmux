import CmuxNextSettings
import Testing

struct NekoIconThemeSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let appearance: [String: JSONValue] = value.map { ["iconTheme": $0] } ?? [:]
        return CmuxConfigSnapshot.parse(.object(["appearance": .object(appearance)]), validDensities: [], validMetrics: [])
    }

    @Test func keyIsReservedAndHidden() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: NekoIconThemeSetting.configPath))
        #expect(!descriptor.isShownOnSettingsPage)
        #expect(!descriptor.isPaletteExposed)
        #expect(descriptor.defaultValue == .string(NekoIconThemeSetting.fallback.rawValue))
    }

    @Test func nekoFallsBackUntilArtworkIsApproved() {
        let reserved = Self.parse(.string("neko"))
        #expect(reserved.iconTheme == .default)
        #expect(!reserved.diagnostics.contains { $0.path == "appearance.iconTheme" })
        #expect(Self.parse(.string("default")).iconTheme == .default)
        #expect(Self.parse(nil).iconTheme == .default)
    }

    @Test func badValueUsesDefaultAndReportsIt() {
        let snapshot = Self.parse(.string("unknown"))
        #expect(snapshot.iconTheme == .default)
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.iconTheme" })
    }
}
