import CmuxNextSettings
import Testing

/// `appearance.liquidGlass`: on by default, so web pages keep their glass; off is one toggle in
/// Appearance, next to Borders.
struct LiquidGlassSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        var root: [String: JSONValue] = [:]
        if let value { root["appearance"] = .object(["liquidGlass": value]) }
        return CmuxConfigSnapshot.parse(.object(root), validDensities: [], validMetrics: [])
    }

    @Test func onByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.liquidGlass)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func theUserCanTurnItOff() {
        #expect(Self.parse(.bool(false)).liquidGlass == false)
        #expect(Self.parse(.bool(true)).liquidGlass)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("off"))
        #expect(snapshot.liquidGlass)
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.liquidGlass" }, "\(snapshot.diagnostics)")
    }

    @Test func itIsOneToggleInAppearance() throws {
        let descriptor = try #require(SettingsSchema.all.first { $0.path == LiquidGlassSetting.configPath })
        #expect(descriptor.section == .appearance)
        #expect(descriptor.kind == .toggle)
        #expect(descriptor.defaultValue == .bool(true))
        #expect(descriptor.isPaletteExposed)
    }
}
