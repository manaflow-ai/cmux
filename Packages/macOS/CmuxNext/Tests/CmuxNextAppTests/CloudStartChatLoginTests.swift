import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloudCredentials
import Foundation
import Testing

/// `cloud.startChat`'s harness login (Leo, 2026-10-31: "A TOKEN GETS PASSED"; DEV and dogfood only).
struct CloudStartChatLoginTests {
    typealias Decision = CloudHarnessLoginDecision

    @Test func theSettingWinsElseOnlyDogfoodBuildsPassALogin() {
        #expect(CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: true, setting: nil))
        #expect(!CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: false, setting: nil))
        #expect(CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: false, setting: true))
        #expect(CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: true, setting: true))
        // `defaults write ... cmux.cloud.passHarnessLogin -bool NO`: a DEV build behaves as production.
        #expect(!CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: true, setting: false))
        #expect(!CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: false, setting: false))
    }

    /// The NEXT nightly is dogfood (only the team uses NEXT Cloud), so it passes the login by
    /// default like a DEV build; the shipping app does not.
    @Test(arguments: [("com.cmuxterm.app.nightly.cmux-next", false, true), ("com.cmuxterm.app.debug.next", true, true),
                      ("com.cmuxterm.app", false, false), ("com.cmuxterm.app.rc", false, false)])
    func dogfoodBundlesPassALoginByDefault(bundleID: String, isDebugBuild: Bool, passes: Bool) {
        let dogfood = DevTools.isAvailable(bundleID: bundleID, isDebugBuild: isDebugBuild)
        #expect(CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: dogfood, setting: nil) == passes)
    }

    /// The switch reads `cmux.cloud.passHarnessLogin` from the defaults it is given.
    @Test func theDefaultsKeyIsTheSwitch() throws {
        let suite = "CloudStartChatLoginTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: true, defaults: defaults))
        #expect(!CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: false, defaults: defaults))
        defaults.set(false, forKey: "cmux.cloud.passHarnessLogin")
        #expect(!CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: true, defaults: defaults))
        defaults.set(true, forKey: "cmux.cloud.passHarnessLogin")
        #expect(CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: false, defaults: defaults))
    }

    /// The decision's rules and their cases are Rust's (cmux-cloud-start-core `harness_login`); this
    /// checks only that the app reaches them over the app FFI and reads every field back.
    @Test func theDecisionComesFromTheRustRules() {
        let first = Decision(gate: true, provider: .claude, signedIn: true, callerOwns: true, guestKind: "owner", machineLogin: CloudMachineLogin.none)
        let verdict = first.verdict
        #expect(verdict.step == .confirmThenInstall && verdict.reason == .confirmFirst)
        #expect(verdict.readsMachine && verdict.guestTakesLogin && !verdict.skippedTeamMachine)
        #expect(verdict.summary == "confirm-then-install (confirm-first): gate on, provider claude, "
            + "signed in yes, caller owns yes, guest owner, machine login none, cached no")
        var declined = Decision(gate: false, provider: .codex, signedIn: true)
        declined.outcome = "declined"
        #expect(declined.step == .skip && declined.reason == .buildGateOff && declined.summary.hasSuffix(" -> declined"))
        #expect(Decision.loginProvider(harness: nil) == .claude && Decision.loginProvider(harness: "codex") == .codex)
        #expect(Decision.loginProvider(harness: "opencode") == nil)
        #expect(Decision.guestKindProbe.contains("/etc/cmux/vm-kind"))
        #expect(Decision.guestKind(stdout: "motd\nvm-kind:team\n") == "team" && Decision.guestKind(stdout: "") == nil)
    }
}
