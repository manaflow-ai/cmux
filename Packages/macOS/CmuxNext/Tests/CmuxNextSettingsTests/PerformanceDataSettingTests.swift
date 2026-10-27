import CmuxNextSettings
import Testing

/// `diagnostics.performanceData` (p09-observability task 134): off by default in every channel, on only for a
/// literal `true`, a privacy key agents may not set, and offered only while its feature is on.
struct PerformanceDataSettingTests {
    private static func snapshot(_ root: JSONValue) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() throws {
        #expect(!Self.snapshot(.object([:])).performanceData)
        let descriptor = try #require(SettingsSchema.descriptor(for: PerformanceDataSetting.path))
        #expect(descriptor.defaultValue == .bool(false))
    }

    @Test(arguments: [JSONValue.bool(false), .string("true"), .number(1), .null])
    func onlyTrueTurnsItOn(value: JSONValue) {
        #expect(!Self.snapshot(.object(["diagnostics": .object(["performanceData": value])])).performanceData)
        #expect(Self.snapshot(.object(["diagnostics": .object(["performanceData": .bool(true)])])).performanceData)
    }

    @Test func agentsMayNotSetIt() {
        #expect(SettingsSchema.agentRefusedKeys["diagnostics.performanceData"] == .privacy)
    }

    @Test func theRowShowsOnlyWhileItsFeatureIsOn() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: PerformanceDataSetting.path))
        #expect(!PerformanceDataSetting().availability(featureEnabled: false).isShown(descriptor))
        #expect(PerformanceDataSetting().availability(featureEnabled: true).isShown(descriptor))
        let merged = SettingsAvailability(hiddenRows: ["energy.saver"], hiddenChoices: ["energy.saver": ["onBattery"]])
            .merging(PerformanceDataSetting().availability(featureEnabled: false))
        #expect(merged.hiddenRows == ["energy.saver", "diagnostics.performanceData"])
        #expect(merged.hiddenChoices == ["energy.saver": ["onBattery"]])
    }
}
