import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// p08-startup-101: the managed policy a launch step applies before the first load is the launch read's forced
/// values (`managedPolicyInEffect`), and the pure readers of the keys the App hands on.
@MainActor struct ManagedPolicyValuesTests {
    @Test func theDeviceValuesReadTheirKeysAndTheTeamOnlyWhileRestricted() {
        let restricted = ManagedDeviceValues(["UpdateChannel": .string("stable"), "MinimumVersion": .string("9.0.0"),
                                              "RestrictToManagedTeam": .bool(true), "ManagedTeam": .string("team_acme")])
        #expect(restricted.channel == "stable")
        #expect(restricted.minimumVersion == "9.0.0")
        #expect(restricted.team == "team_acme")
        #expect(ManagedDeviceValues(["ManagedTeam": .string("team_acme")]).team == nil, "a team with no restriction is handed on")
        #expect(ManagedDeviceValues(["URLBlocklist": .array([.string("*")])]) == ManagedDeviceValues([:]), "another key changed the values")
    }

    @Test func theURLFiltersAreTheStringListsOfBothPolicies() {
        let filters = ManagedURLFilters(["URLBlocklist": .array([.string("*"), .number(1)]), "URLAllowlist": .array([.string("example.com")])])
        #expect(filters.blocklist == ["*"], "a non-string entry is no filter")
        #expect(filters.allowlist == ["example.com"])
        #expect(ManagedURLFilters(["URLBlocklist": .string("*")]).blocklist.isEmpty, "a value that is not a list is no filter")
    }

    /// Before the first load `managedPolicy` is empty; the policy in effect is the launch read's forced values (read
    /// off main), and the load's policy after it. The controller's own reader has no policy, so a second read shows.
    @Test func thePolicyInEffectIsTheLaunchReadsUntilTheFirstLoad() async throws {
        let url = try SettingsLaunchReadTests.file("{}")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let blocklist = JSONValue.array([.string("blocked.example")])
        let launch = try await SettingsLaunchReadTests.endedRead(of: url, managed: ManagedPreferences(forced: ["URLBlocklist": blocklist]))
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [], launch: launch)
        #expect(settings.managedPolicy.isEmpty)
        #expect(settings.managedPolicyInEffect["URLBlocklist"] == blocklist, "a step before the load applies no policy")
        settings.start()
        defer { settings.stop() }
        #expect(settings.loadCount == 1)
        #expect(settings.managedPolicyInEffect == settings.managedPolicy)
        #expect(settings.managedPolicyInEffect["URLBlocklist"] == blocklist, "the first load dropped the launch's policy")
    }
}
