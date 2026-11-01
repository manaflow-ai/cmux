import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloudCredentials
import Foundation
import Testing

/// `cloud.startChat`'s harness login (Leo, 2026-10-31: "A TOKEN GETS PASSED"; DEV and dogfood only).
struct CloudStartChatLoginTests {
    typealias Step = CloudStartChat.LoginStep

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

    @Test func harnessFamiliesMapToTheirProvider() {
        #expect(CloudStartChat.loginProvider(harness: nil) == .claude)
        #expect(CloudStartChat.loginProvider(harness: "") == .claude)
        #expect(CloudStartChat.loginProvider(harness: "claude") == .claude)
        #expect(CloudStartChat.loginProvider(harness: "claude-sr2") == .claude)
        #expect(CloudStartChat.loginProvider(harness: "codex") == .codex)
        #expect(CloudStartChat.loginProvider(harness: "opencode") == nil)
    }

    @Test func aCachedLoginInstallsSilentlyAndTheFirstOneAsksOnce() {
        func step(enabled: Bool = true, provider: CloudCredentialTransfer.Provider? = .claude, user: Bool = true,
                  owns: Bool = true, ownerGuest: Bool = true, has: Bool = false, cached: Bool = false) -> Step {
            CloudStartChat.loginStep(enabled: enabled, provider: provider, signedInUser: user, callerOwns: owns,
                                     ownerGuest: ownerGuest, machineHasLogin: has, cachedLogin: cached)
        }
        #expect(step(cached: true) == .install)
        #expect(step(cached: false) == .confirmThenInstall)
        // Never: a production build, a machine the caller does not own (a teammate's), one that
        // already has a login, no signed-in user, or a harness whose login stays per machine.
        #expect(step(enabled: false, cached: true) == .skip)
        #expect(step(owns: false, cached: true) == .skip)
        // A team guest, even the caller's own (a creator's team machine): skipped before any confirm,
        // since the transfer's preflight refuses a guest whose Unix user teammates share.
        #expect(step(ownerGuest: false, cached: true) == .skip)
        #expect(step(ownerGuest: false, cached: false) == .skip)
        #expect(step(has: true, cached: true) == .skip)
        #expect(step(user: false, cached: true) == .skip)
        #expect(step(provider: .codex, cached: true) == .skip)
        #expect(step(provider: nil) == .skip)
    }

    @Test func theMachineProbeUsesTheImagesOwnDetection() {
        #expect(CloudStartChat.machineLoginProbe.contains("cmux_agent_has_own_login claude"))
        #expect(!CloudStartChat.machineLoginProbe.contains("sk-ant"))
        #expect(CloudStartChat.ownerGuestProbe.contains("/etc/cmux/vm-kind"))
    }
}
