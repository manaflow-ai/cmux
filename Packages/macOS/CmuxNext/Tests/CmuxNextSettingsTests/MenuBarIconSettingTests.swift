import CmuxNextSettings
import Testing

/// `app.showMenuBarIcon`: the cmux menu bar item is on by default (user 2026-10-27), the setting turns
/// it off, a bad value keeps the default and says why, and the row is in Settings > General.
struct MenuBarIconSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let app: [String: JSONValue] = value.map { ["showMenuBarIcon": $0] } ?? [:]
        return CmuxConfigSnapshot.parse(.object(["app": .object(app)]), validDensities: [], validMetrics: [])
    }

    @Test func onByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.showMenuBarIcon)
        #expect(CmuxConfigSnapshot.showMenuBarIconFallback)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func offWhenSetFalse() {
        let snapshot = Self.parse(.bool(false))
        #expect(!snapshot.showMenuBarIcon)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func badValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("yes"))
        #expect(snapshot.showMenuBarIcon)
        #expect(snapshot.diagnostics.map(\.path) == ["app.showMenuBarIcon"])
    }

    @Test func rowIsInGeneralWithTheSameDefault() throws {
        let row = try #require(SettingsSchema.descriptor(for: CmuxConfigSnapshot.showMenuBarIconPath))
        #expect(row.kind == .toggle)
        #expect(row.section == .general)
        #expect(row.defaultValue == .bool(true))
        #expect(row.title == "Show Menu Bar Icon")
    }
}
