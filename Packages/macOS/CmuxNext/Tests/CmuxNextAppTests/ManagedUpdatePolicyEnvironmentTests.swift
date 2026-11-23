@testable import CmuxNextUpdater
import Testing

/// `CMUX_DISABLE_AUTO_UPDATE=1` turns the updater off for one launched process, exactly as a
/// forced `DisableAutoUpdate` profile does. A CI harness's copy of an older build otherwise saw a
/// newer one, downloaded it, and Sparkle's installer asked an unattended Mac for an admin password.
@Suite struct ManagedUpdatePolicyEnvironmentTests {
    @Test func theEnvironmentSwitchDisablesUpdates() {
        let policy = ManagedUpdatePolicy.live(bundleIdentifier: ManagedUpdatePolicy.releaseDomain,
                                              environment: [ManagedUpdatePolicy.environmentKey: "1"])
        #expect(policy.disablesUpdates)
    }

    @Test func unsetOrOtherValuesLeaveThePolicyAsTheProfileSays() {
        // No profile forces DisableAutoUpdate on a test host, so only the variable could turn it on.
        for environment: [String: String] in [[:], [ManagedUpdatePolicy.environmentKey: "0"],
                                              [ManagedUpdatePolicy.environmentKey: ""]] {
            let policy = ManagedUpdatePolicy.live(bundleIdentifier: ManagedUpdatePolicy.releaseDomain,
                                                  environment: environment)
            #expect(!policy.disablesUpdates, "environment \(environment)")
        }
    }

    @Test func theSwitchHasTheNameHarnessesSet() {
        #expect(ManagedUpdatePolicy.environmentKey == "CMUX_DISABLE_AUTO_UPDATE")
    }
}
