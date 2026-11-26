import CmuxNextSettings
import Testing

/// Settings > Advanced > Experiments > Publish Previews as Apps (`experiments.appsTier`, RFD 0003):
/// off unless cmux.json turns it on, and a value that is no bool keeps it off.
struct AppsTierSettingTests {
    private func appsTier(_ value: JSONValue?) -> Bool? {
        let root: JSONValue = value.map { .object(["experiments": .object(["appsTier": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []).experimentSwitches["appsTier"]
    }

    @Test func offByDefault() throws {
        let row = try #require(SettingsSchema.descriptor(for: CmuxConfigSnapshot.appsTierPath))
        #expect(row.defaultValue == .bool(false))
        #expect(row.kind == .toggle)
        #expect(appsTier(nil) == false)
    }

    @Test func cmuxJsonTurnsItOn() {
        #expect(appsTier(.bool(true)) == true)
        #expect(appsTier(.bool(false)) == false)
    }

    @Test func aValueThatIsNoBoolKeepsItOff() {
        #expect(appsTier(.string("yes")) == false)
    }
}
