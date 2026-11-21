import CmuxNextSettings
import Testing

struct NekoIconThemeSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let appearance: [String: JSONValue] = value.map { ["iconTheme": $0] } ?? [:]
        return CmuxConfigSnapshot.parse(.object(["appearance": .object(appearance)]), validDensities: [], validMetrics: [])
    }

    /// Leo: "i also want optional neko icons": a Settings row, off by default.
    @Test func keyIsOnTheSettingsPageAndOffByDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: NekoIconThemeSetting.configPath))
        #expect(descriptor.isShownOnSettingsPage)
        #expect(descriptor.defaultValue == .string(NekoIconTheme.default.rawValue))
        #expect(NekoIconThemeSetting.fallback == .default)
    }

    @Test func nekoIsKept() {
        let chosen = Self.parse(.string("neko"))
        #expect(chosen.iconTheme == .neko)
        #expect(!chosen.diagnostics.contains { $0.path == "appearance.iconTheme" })
        #expect(Self.parse(.string("default")).iconTheme == .default)
        #expect(Self.parse(nil).iconTheme == .default)
    }

    @Test func badValueUsesDefaultAndReportsIt() {
        let snapshot = Self.parse(.string("unknown"))
        #expect(snapshot.iconTheme == .default)
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.iconTheme" })
    }
}
