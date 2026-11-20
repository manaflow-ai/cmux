import CmuxNextSettings
import Testing

struct AppsTierSettingTests {
    @Test func appsTierIsOffUntilEnabled() throws {
        let row = try #require(SettingsSchema.descriptor(for: CmuxConfigSnapshot.appsTierPath))
        #expect(row.defaultValue == .bool(false))
        #expect(!CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: []).appsTier)
        let enabled = JSONValue.object(["experiments": .object(["apps_tier": .bool(true)])])
        #expect(CmuxConfigSnapshot.parse(enabled, validDensities: [], validMetrics: []).appsTier)
        let invalid = JSONValue.object(["experiments": .object(["apps_tier": .string("yes")])])
        let snapshot = CmuxConfigSnapshot.parse(invalid, validDensities: [], validMetrics: [])
        #expect(!snapshot.appsTier)
        #expect(snapshot.diagnostics.contains { $0.path == "experiments.apps_tier" })
    }
}
