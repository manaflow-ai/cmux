@testable import CmuxNextApp
import CmuxNextCloudCredentials
import Testing

/// `cloud.startChat`'s harness login (Leo, 2026-10-31: "A TOKEN GETS PASSED"; DEV and dogfood only).
struct CloudStartChatLoginTests {
    typealias Step = CloudStartChat.LoginStep

    @Test func onlyDebugBuildsOrTheExplicitOptInPassALogin() {
        #expect(CloudStartChat.passesHarnessLogin(isDebugBuild: true, optedIn: false))
        #expect(CloudStartChat.passesHarnessLogin(isDebugBuild: false, optedIn: true))
        #expect(!CloudStartChat.passesHarnessLogin(isDebugBuild: false, optedIn: false))
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

    /// Leo's machines are all team-account machines he created (guest kind `team`), so a DEV build lets
    /// the creator's team guest take the login (the platform's owner answer still required); without
    /// that allowance it stays skipped, as in production.
    @Test func aDevBuildPassesTheLoginToTheCreatorsTeamMachine() {
        func step(owns: Bool = true, creatorTeam: Bool, cached: Bool = true) -> Step {
            CloudStartChat.loginStep(enabled: true, provider: .claude, signedInUser: true, callerOwns: owns,
                                     ownerGuest: false, creatorTeamGuest: creatorTeam, machineHasLogin: false, cachedLogin: cached)
        }
        #expect(step(creatorTeam: true) == .install)
        #expect(step(creatorTeam: true, cached: false) == .confirmThenInstall)
        #expect(step(creatorTeam: false) == .skip)
        // A teammate's team machine: the platform does not answer owner, so never.
        #expect(step(owns: false, creatorTeam: true) == .skip)
        #expect(CloudStartChat.teamGuestProbe.contains("= team"))
    }

    @Test func theMachineProbeUsesTheImagesOwnDetection() {
        #expect(CloudStartChat.machineLoginProbe.contains("cmux_agent_has_own_login claude"))
        #expect(!CloudStartChat.machineLoginProbe.contains("sk-ant"))
        #expect(CloudStartChat.ownerGuestProbe.contains("/etc/cmux/vm-kind"))
    }
}
