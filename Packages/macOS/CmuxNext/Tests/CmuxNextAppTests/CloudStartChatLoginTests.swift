import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloudCredentials
import Foundation
import Testing

/// `cloud.startChat`'s harness login (Leo, 2026-10-31: "A TOKEN GETS PASSED"; DEV and dogfood only).
struct CloudStartChatLoginTests {
    typealias Decision = CloudHarnessLoginDecision

    /// The NEXT nightly is dogfood (only the team uses NEXT Cloud), so it passes the login by
    /// default like a DEV build; the shipping app does not.
    @Test(arguments: [("com.cmuxterm.app.nightly.cmux-next", false, true), ("com.cmuxterm.app.debug.next", true, true),
                      ("com.cmuxterm.app", false, false), ("com.cmuxterm.app.rc", false, false)])
    func dogfoodBundlesPassALoginByDefault(bundleID: String, isDebugBuild: Bool, passes: Bool) throws {
        let dogfood = DevTools.isAvailable(bundleID: bundleID, isDebugBuild: isDebugBuild)
        let suite = "CloudStartChatLoginTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: dogfood, defaults: defaults) == passes)
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
        #expect(CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: true, defaults: defaults))
        // Release never passes a login, whatever the default says.
        #expect(!CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: false, defaults: defaults))
    }

    /// The decision's rules and their cases are Rust's (cmux-cloud-start-core `harness_login`); this
    /// checks only that the app reaches them in the one call and reads every field back.
    @Test func theDecisionComesFromTheRustRules() {
        var first = Decision(dogfood: true, setting: nil, harness: nil, signedIn: true)
        first.callerOwns = true
        let probe = first.verdict.guestKindProbe
        #expect(first.readsMachine && probe.contains("/etc/cmux/vm-kind"))
        first.guestStdout = "motd\nvm-kind:owner\n"
        first.machineProbe = .init(exitCode: 0, stdout: "none\n")
        let verdict = first.verdict
        #expect(verdict.step == .confirmThenInstall && verdict.reason == .confirmFirst)
        #expect(verdict.readsMachine && verdict.guestTakesLogin && !verdict.skippedTeamMachine)
        #expect(first.provider == .claude && first.guestKind == "owner" && verdict.machineLogin == CloudMachineLogin.none && first.gate)
        #expect(verdict.summary == "confirm-then-install (confirm-first): gate on, provider claude, "
            + "signed in yes, caller owns yes, guest owner, machine login none, cached no")
        var declined = Decision(dogfood: true, setting: false, harness: "codex", signedIn: true)
        declined.outcome = "declined"
        #expect(declined.step == .skip && declined.reason == .buildGateOff && declined.summary.hasSuffix(" -> declined"))
        #expect(declined.provider == .codex && Decision(dogfood: true, setting: nil, harness: "opencode", signedIn: true).provider == nil)
    }
}
