import Foundation
import Testing
@testable import CmuxMobileShell

struct MultiMacAggregationFlagTests {
    @Test func defaultIsEnabledWithoutEnvironmentOrDefaultsKey() {
        let scopedDefaults = Self.makeDefaults()
        defer { Self.removeDefaults(scopedDefaults) }

        #expect(MultiMacAggregationFlag(environment: [:], defaults: scopedDefaults.defaults).isEnabled)
    }

    @Test(arguments: ["0", "false", "off", "no", " FALSE ", "Off", "maybe"])
    func environmentDisablesAggregation(_ value: String) {
        let scopedDefaults = Self.makeDefaults()
        defer { Self.removeDefaults(scopedDefaults) }
        scopedDefaults.defaults.set(true, forKey: "multiMacAggregation")

        #expect(!MultiMacAggregationFlag(
            environment: ["CMUX_MULTI_MAC_AGGREGATION": value],
            defaults: scopedDefaults.defaults
        ).isEnabled)
    }

    @Test(arguments: ["1", "true", "yes", "on", " TRUE ", "YeS"])
    func environmentEnablesAggregation(_ value: String) {
        let scopedDefaults = Self.makeDefaults()
        defer { Self.removeDefaults(scopedDefaults) }
        scopedDefaults.defaults.set(false, forKey: "multiMacAggregation")

        #expect(MultiMacAggregationFlag(
            environment: ["CMUX_MULTI_MAC_AGGREGATION": value],
            defaults: scopedDefaults.defaults
        ).isEnabled)
    }

    @Test(arguments: [false, true])
    func defaultsControlAggregationWhenEnvironmentIsUnset(_ value: Bool) {
        let scopedDefaults = Self.makeDefaults()
        defer { Self.removeDefaults(scopedDefaults) }
        scopedDefaults.defaults.set(value, forKey: "multiMacAggregation")

        #expect(MultiMacAggregationFlag(environment: [:], defaults: scopedDefaults.defaults).isEnabled == value)
    }

    private static func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "multi-mac-aggregation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private static func removeDefaults(_ scopedDefaults: (defaults: UserDefaults, suiteName: String)) {
        scopedDefaults.defaults.removePersistentDomain(forName: scopedDefaults.suiteName)
    }
}
