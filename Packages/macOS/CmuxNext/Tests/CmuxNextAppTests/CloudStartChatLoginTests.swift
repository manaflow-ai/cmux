import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloudCredentials
import CmuxNextDaemon
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

    @Test func harnessFamiliesMapToTheirProvider() {
        #expect(CloudStartChat.loginProvider(harness: nil) == .claude)
        #expect(CloudStartChat.loginProvider(harness: "") == .claude)
        #expect(CloudStartChat.loginProvider(harness: "claude") == .claude)
        #expect(CloudStartChat.loginProvider(harness: "claude-sr2") == .claude)
        #expect(CloudStartChat.loginProvider(harness: "codex") == .codex)
        #expect(CloudStartChat.loginProvider(harness: "opencode") == nil)
    }

    @Test func aCachedLoginInstallsSilentlyAndTheFirstOneAsksOnce() {
        func decide(gate: Bool = true, provider: CloudCredentialTransfer.Provider? = .claude, user: Bool = true, owns: Bool? = true,
                    kind: String? = "owner", login: CloudMachineLogin? = CloudMachineLogin.none, cached: Bool = false) -> Decision {
            Decision(gate: gate, provider: provider, signedIn: user, callerOwns: owns, guestKind: kind, machineLogin: login, cached: cached)
        }
        #expect(decide(cached: true).step == .install && decide(cached: true).reason == .installCached)
        #expect(decide().step == .confirmThenInstall && decide().reason == .confirmFirst)
        // A rejected login is replaced like a missing one.
        #expect(decide(login: .rejected, cached: true).step == .install)
        // Never, each with its own reason: a production build, a harness whose login stays per machine, no
        // signed-in user, a machine the caller does not own (a teammate's), a guest with no known kind, a
        // guest whose kind could not be read, or a login there that stays.
        let skips: [(Decision, Decision.Reason)] = [
            (decide(gate: false, cached: true), .buildGateOff), (decide(provider: .codex, cached: true), .noTransfer),
            (decide(provider: nil), .noTransfer), (decide(user: false, cached: true), .signedOut),
            (decide(owns: false, cached: true), .callerNotOwner), (decide(owns: nil, cached: true), .callerNotOwner),
            (decide(kind: "", cached: true), .guestNotOwner), (decide(kind: "shared", cached: true), .guestNotOwner),
            (decide(kind: nil, cached: true), .guestUnread),
            (decide(login: .working, cached: true), .machineLoginKept), (decide(login: .cached, cached: true), .machineLoginKept),
            (decide(login: .session, cached: true), .machineLoginKept),
        ]
        for (decision, reason) in skips {
            #expect(decision.step == .skip)
            #expect(decision.reason == reason)
        }
        // The creator's own machine takes the login on a team account too (Leo, 2026-11-01: "team or no
        // team the thing should just work"); a teammate's never does (the platform does not answer owner).
        #expect(decide(kind: "team", cached: true).step == .install && decide(kind: "team").step == .confirmThenInstall)
        #expect(decide(kind: "team").guestTakesLogin && decide().guestTakesLogin && !decide(kind: "").guestTakesLogin)
        #expect(decide(owns: false, kind: "team", cached: true).reason == .callerNotOwner)
        // Only a decision that got that far reads the machine.
        #expect(decide().readsMachine && !decide(owns: false).readsMachine && !decide(gate: false).readsMachine)
    }

    /// The start's record (the log and `cloud.machines`' `harness_login`) names the step, the reason and every input.
    @Test func theRecordSaysWhyItSkipped() {
        var decision = Decision(gate: true, provider: .claude, signedIn: true, callerOwns: true, guestKind: "", cached: true)
        #expect(decision.summary == "skip (guest-not-owner): gate on, provider claude, signed in yes, caller owns yes, guest (none), machine login -, cached yes")
        decision = Decision(gate: true, provider: .claude, signedIn: true, callerOwns: true, guestKind: "team", cached: true)
        #expect(decision.summary == "install (install-cached): gate on, provider claude, signed in yes, caller owns yes, guest team, machine login -, cached yes")
        decision = Decision(gate: true, provider: .claude, signedIn: true, callerOwns: true, guestKind: "owner", machineLogin: .rejected, cached: true)
        decision.outcome = "installed"
        #expect(decision.summary.hasPrefix("install (install-cached): "))
        #expect(decision.summary.hasSuffix("guest owner, machine login rejected, cached yes -> installed"))
        #expect(Decision(gate: false, provider: .claude, signedIn: true).summary.hasPrefix("skip (build-gate-off): gate off"))
        #expect(Decision(gate: true, provider: .claude, signedIn: true, callerOwns: true, guestKind: "").summary.contains("guest (none)"))
    }

    /// The creator's team guest is no longer skipped, so it never marks the chat's card a team machine
    /// (handshake `cloudTeamMachine`).
    @Test func aCreatorsTeamGuestIsNotASkippedTeamMachine() {
        #expect(!Decision(gate: true, provider: .claude, signedIn: true, callerOwns: true, guestKind: "team").skippedTeamMachine)
        #expect(!Decision(gate: true, provider: .claude, signedIn: true, callerOwns: true, guestKind: "").skippedTeamMachine)
        #expect(!Decision(gate: true, provider: .claude, signedIn: true, callerOwns: true, guestKind: "owner").skippedTeamMachine)
        #expect(!Decision(gate: false, provider: .claude, signedIn: true, guestKind: "team").skippedTeamMachine)
        #expect(!Decision(gate: true, provider: .claude, signedIn: true, callerOwns: false, guestKind: "team").skippedTeamMachine)
        var handshake = AgentPaneHandshake(transport: .mock)
        handshake.cloudTeamMachine = true
        let coded = String(decoding: (try? JSONEncoder().encode(handshake)) ?? Data(), as: UTF8.self)
        #expect(coded.contains("\"cloudTeamMachine\":true"))
    }

    /// The guest's kind comes after a marker, so an exec that ran is told from one that failed.
    @Test func theGuestProbeReadsTheVMKind() async throws {
        #expect(Decision.guestKindProbe.contains("/etc/cmux/vm-kind"))
        #expect(Decision.guestKind(stdout: "vm-kind:owner\n") == "owner")
        #expect(Decision.guestKind(stdout: "motd\nvm-kind:team\n") == "team")
        #expect(Decision.guestKind(stdout: "vm-kind:\n") == "")
        #expect(Decision.guestKind(stdout: "") == nil)
        let ran = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", Decision.guestKindProbe],
                                              environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(10), clock: ContinuousClock())
        // No /etc/cmux/vm-kind on the test host: the probe still answers, with an empty kind.
        #expect(ran.status == 0)
        #expect(Decision.guestKind(stdout: String(decoding: ran.stdout, as: UTF8.self)) == "")
    }
}
