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

        #expect(rules == [
            .port(24_678),
            .range(49_152...65_535),
        ])
        #expect(rules.map(\.canonicalText) == ["24678", "49152-65535"])
    }

    @Test("Exact ports round-trip through canonical UserDefaults strings")
    func exactPortsRoundTripThroughUserDefaults() {
        let rule = SidebarIgnoredPortRule.port(24_678)

        #expect(rule.encodeForUserDefaults() as? String == "24678")
        #expect(SidebarIgnoredPortRule.decodeFromUserDefaults("24678") == rule)
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
    func customOverrideFiltersExactPortsAndRanges() {
        let policy = SidebarPortVisibilityPolicy(ignoredRules: [
            .port(3_001),
            .range(8_000...8_010),
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
}
