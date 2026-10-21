import CmuxNextBrowser
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// A company that set Chrome's IntranetRedirectBehavior policy gets the same
/// bare-word intranet behavior in cmux, with no cmux setup. The managed
/// values are fixed here, never this Mac's profiles.
@Suite struct ChromeIntranetPolicyTests {
    private func behavior(forced: [String: JSONValue] = [:], recommended: [String: JSONValue] = [:]) -> IntranetRedirectBehavior {
        ChromeIntranetPolicy(reader: FixedManagedPreferenceReader(ManagedPreferences(forced: forced, recommended: recommended))).behavior()
    }

    @Test func unsetIsChromesDefault() {
        #expect(behavior() == .withInterceptionCheck)
    }

    @Test func policyOneTurnsTheCheckOff() {
        #expect(behavior(forced: ["IntranetRedirectBehavior": .number(1)]) == .disabled)
    }

    @Test func policyTwoSkipsTheInterceptionCheck() {
        #expect(behavior(recommended: ["IntranetRedirectBehavior": .number(2)]) == .withoutInterceptionCheck)
    }

    @Test func aForcedValueWins() {
        #expect(behavior(forced: ["IntranetRedirectBehavior": .number(1)], recommended: ["IntranetRedirectBehavior": .number(3)]) == .disabled)
    }
}
