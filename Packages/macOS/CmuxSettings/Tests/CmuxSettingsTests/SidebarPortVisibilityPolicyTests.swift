import Foundation
import Testing
@testable import CmuxSettings

@Suite("Sidebar port visibility policy")
struct SidebarPortVisibilityPolicyTests {
    @Test("Mixed exact ports and ranges decode from JSON")
    func mixedRulesDecodeFromJSON() throws {
        let rules = try #require([SidebarIgnoredPortRule].decodeFromJSON([
            NSNumber(value: 24_678),
            " 49152 - 65535 ",
        ]))
        let exactPort = try #require(SidebarIgnoredPortRule(port: 24_678))
        let ephemeralRange = try #require(SidebarIgnoredPortRule(range: 49_152...65_535))

        #expect(rules == [
            exactPort,
            ephemeralRange,
        ])
        #expect(rules.map(\.canonicalText) == ["24678", "49152-65535"])
    }

    @Test("Exact ports round-trip through canonical UserDefaults strings")
    func exactPortsRoundTripThroughUserDefaults() throws {
        let rule = try #require(SidebarIgnoredPortRule(port: 24_678))

        #expect(rule.encodeForUserDefaults() as? String == "24678")
        #expect(SidebarIgnoredPortRule.decodeFromUserDefaults("24678") == rule)
    }

    @Test("JSON keeps exact ports numeric and ranges textual")
    func jsonKeepsExactPortsNumericAndRangesTextual() throws {
        let exactPort = try #require(SidebarIgnoredPortRule(port: 24_678))
        let range = try #require(SidebarIgnoredPortRule(range: 49_152...65_535))

        #expect(exactPort.encodeForJSON() as? Int == 24_678)
        #expect(range.encodeForJSON() as? String == "49152-65535")
        #expect(SidebarIgnoredPortRule.decodeFromJSON("24678") == nil)
    }

    @Test("Default policy keeps 49151 and excludes both ephemeral boundaries")
    func defaultPolicyFiltersEphemeralBoundaries() {
        let visible = SidebarPortVisibilityPolicy().visiblePorts(from: [
            49_151,
            49_152,
            65_535,
        ])

        #expect(visible == [49_151])
    }

    @Test("Empty override shows every detected port")
    func emptyOverrideShowsEveryPort() {
        let visible = SidebarPortVisibilityPolicy(ignoredRules: [])
            .visiblePorts(from: [3_000, 49_152, 65_535])

        #expect(visible == [3_000, 49_152, 65_535])
    }

    @Test("Custom override supports exact ports and ranges")
    func customOverrideFiltersExactPortsAndRanges() throws {
        let exactPort = try #require(SidebarIgnoredPortRule(port: 3_001))
        let range = try #require(SidebarIgnoredPortRule(range: 8_000...8_010))
        let policy = SidebarPortVisibilityPolicy(ignoredRules: [
            exactPort,
            range,
        ])

        #expect(policy.visiblePorts(from: [3_000, 3_001, 8_000, 8_005, 8_011]) == [3_000, 8_011])
    }

    @Test(
        "Invalid textual rules are rejected",
        arguments: [
            "0",
            "65536",
            "49152-",
            "49152-65536",
            "65535-49152",
            "49152-65535-65535",
            "24678",
        ]
    )
    func invalidTextualRulesAreRejected(_ rawValue: String) {
        #expect(SidebarIgnoredPortRule.decodeFromJSON(rawValue) == nil)
    }

    @Test("Boolean and fractional JSON numbers are rejected")
    func nonIntegerJSONNumbersAreRejected() {
        #expect(SidebarIgnoredPortRule.decodeFromJSON(NSNumber(value: true)) == nil)
        #expect(SidebarIgnoredPortRule.decodeFromJSON(NSNumber(value: 49_152.5)) == nil)
    }

    @Test("Invalid values cannot construct port rules")
    func invalidValuesCannotConstructPortRules() {
        #expect(SidebarIgnoredPortRule(port: 0) == nil)
        #expect(SidebarIgnoredPortRule(port: 65_536) == nil)
        #expect(SidebarIgnoredPortRule(range: 0...1) == nil)
        #expect(SidebarIgnoredPortRule(range: 65_535...65_536) == nil)
    }

    @Test("Malformed UserDefaults entries fall back to the default policy")
    func malformedUserDefaultsEntriesFallBackToDefaultPolicy() throws {
        let suiteName = "SidebarPortVisibilityPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = SettingCatalog().sidebar.ignoredPorts
        let settings = UserDefaultsSettingsClient(defaults: defaults)

        defaults.set([true], forKey: key.userDefaultsKey)
        #expect(settings.value(for: key) == SidebarPortVisibilityPolicy.defaultIgnoredRules)

        defaults.set([49_152.5], forKey: key.userDefaultsKey)
        #expect(settings.value(for: key) == SidebarPortVisibilityPolicy.defaultIgnoredRules)
    }
}
