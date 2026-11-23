import CmuxNextSettings
import Testing

/// `appearance.liquidGlass`: off by default (Lawrence, standup 2026-11-19), so web pages draw
/// solid; on is one toggle in Appearance, next to Borders.
struct LiquidGlassSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        var root: [String: JSONValue] = [:]
        if let value { root["appearance"] = .object(["liquidGlass": value]) }
        return CmuxConfigSnapshot.parse(.object(root), validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.liquidGlass == false)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func theUserCanTurnItOnAndOff() {
        #expect(Self.parse(.bool(false)).liquidGlass == false)
        #expect(Self.parse(.bool(true)).liquidGlass)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("on"))
        #expect(snapshot.liquidGlass == false)
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.liquidGlass" }, "\(snapshot.diagnostics)")
    }

    @Test func itIsOneToggleInAppearance() throws {
        let descriptor = try #require(SettingsSchema.all.first { $0.path == LiquidGlassSetting.configPath })
        #expect(descriptor.section == .appearance)
        #expect(descriptor.kind == .toggle)
        #expect(descriptor.defaultValue == .bool(false))
        #expect(descriptor.isPaletteExposed)
    }
}
