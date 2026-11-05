import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloudCredentials
import CmuxNextWakeupsTestSupport
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
        // Release: the setting alone never turns it on; only the remote switch, and NO keeps it off.
        defaults.set(true, forKey: "cmux.cloud.passHarnessLogin")
        #expect(CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: true, defaults: defaults))
        #expect(!CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: false, defaults: defaults))
        #expect(CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: false, defaults: defaults, remoteSwitch: true))
        #expect(!CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: false, defaults: defaults, remoteSwitch: false))
        defaults.set(false, forKey: "cmux.cloud.passHarnessLogin")
        #expect(!CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: false, defaults: defaults, remoteSwitch: true))
    }

    /// Leo, 2026-11-02: Release copies the login only with the switch on, after the one-time consent,
    /// and only to an owner guest. The cases are Rust's; this checks the app's fields reach them.
    @Test func releaseAsksConsentOnceAndFollowsTheSwitch() {
        var start = Decision(dogfood: false, setting: nil, harness: nil, signedIn: true)
        start.remoteSwitch = true
        start.callerOwns = true
        start.guestStdout = "vm-kind:owner\n"
        start.machineProbe = .init(exitCode: 0, stdout: "none\n")
        #expect(start.step == .askConsent && start.reason == .consentFirst)
        start.consent = true
        #expect(start.step == .install && start.reason == .installChosen)
        start.consent = false
        #expect(start.step == .skip && start.reason == .consentDeclined)
        start.consent = true
        start.remoteSwitch = nil
        #expect(start.step == .skip && start.reason == .remoteSwitchOff && !start.gate)
        start.remoteSwitch = true
        start.guestStdout = "vm-kind:team\n"
        #expect(start.reason == .guestNotOwner && !start.guestTakesLogin)
    }

    /// A machine created just now has no guest kind until its guest binds: the start reads it again, as the
    /// transfer does, instead of skipping the login. A recorded kind or a failed exec is read once.
    @Test func aNewMachinesGuestKindIsReadAgainUntilItBinds() async throws {
        var start = Decision(dogfood: true, setting: nil, harness: nil, signedIn: true)
        start.callerOwns = true
        let guest = Guest(["vm-kind:\n", "vm-kind:\n", "vm-kind:owner\n"])
        try await start.readGuest(exec: { _ in await guest.read() }, pause: { await guest.pause() })
        let (reads, pauses) = await guest.counts
        #expect(start.guestKind == "owner" && start.guestTakesLogin && reads == 3 && pauses == 2)
        for answer in ["vm-kind:team\n", nil] {
            var other = Decision(dogfood: true, setting: nil, harness: nil, signedIn: true)
            other.callerOwns = true
            let once = Guest([answer])
            try await other.readGuest(exec: { _ in await once.read() }, pause: { await once.pause() })
            let (onceReads, oncePauses) = await once.counts
            #expect(onceReads == 1 && oncePauses == 0)
        }
    }

    /// The kind read's budget holds in elapsed time: a guest whose exec is slow is cut off at the budget, not
    /// after the read in flight finishes, and the start goes on without a kind (no login is copied).
    ///
    /// The budget runs on a ``ManualClock`` the test advances by hand, and the slow exec waits on a second
    /// one the test never advances, so the only way the read can end is the budget cutting it off: nothing
    /// here waits on real time, and a read that waited for its exec hangs the test instead of passing on a
    /// fast runner.
    @Test func aSlowGuestKindReadIsCutOffAtTheBudget() async throws {
        var start = Decision(dogfood: true, setting: nil, harness: nil, signedIn: true)
        start.callerOwns = true
        let budget = Duration.milliseconds(200)
        let clock = ManualClock(), slowExec = ManualClock()
        // The budget's deadline is the only thing that ever waits on `clock`: once it is set, the budget passes.
        let passTheBudget = Task { try await clock.waitForSleeper(); clock.advance(by: budget) }
        try await start.readGuest(exec: { _ in await Self.guestKindTooSlowToAnswer(waitingOn: slowExec) },
                                  pause: {}, budget: budget, clock: clock)
        try await passTheBudget.value
        // Cut off at the budget: the read in flight was cancelled (it left `slowExec`) and its answer was
        // never taken, so the start goes on with no kind, and the budget is all the time the read spent.
        #expect(!start.guestTakesLogin && start.guestStdout == nil)
        #expect(slowExec.sleeperCount == 0 && clock.now.offset == budget)
    }

    /// A guest exec too slow to answer within the read's budget: it waits on a clock its test never
    /// advances, so it answers only if the read waits for it instead of cutting it off.
    nonisolated static func guestKindTooSlowToAnswer(waitingOn clock: ManualClock) async -> String? {
        try? await clock.sleep(for: .seconds(2))
        return "vm-kind:\n"
    }

    /// A scripted guest: its kind answers in order (the last repeats), and how many reads and pauses it saw.
    actor Guest {
        var answers: [String?], reads = 0, pauses = 0
        init(_ answers: [String?]) { self.answers = answers }
        var counts: (Int, Int) { (reads, pauses) }
        func read() -> String? {
            reads += 1
            return answers.count > 1 ? answers.removeFirst() : answers.first ?? nil
        }
        func pause() { pauses += 1 }
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

    /// Leo, 2026-11-02: a CLI or agent run never waits on a confirm; it takes the machine's login,
    /// the person's kept choice or `--login`, and with none of them fails at once.
    @Test func aHeadlessRunDecidesAtOnce() {
        func decision(_ ask: CloudHarnessLoginAsk, stored: Decision.Choice? = nil, machine: String = "none\n") -> Decision {
            var decision = Decision(dogfood: true, setting: nil, harness: nil, signedIn: true)
            (decision.requested, decision.requestedByPerson, decision.headless) = (ask.requested, ask.byPerson && ask.requested != nil, ask.headless)
            (decision.stored, decision.callerOwns, decision.guestStdout) = (stored, true, "vm-kind:owner\n")
            decision.machineProbe = .init(exitCode: 0, stdout: machine)
            return decision
        }
        let headless = CloudHarnessLoginAsk(headless: true)
        #expect(decision(headless).step == .refuse && decision(headless).reason == .needsLoginChoice)
        #expect(decision(headless, stored: Decision.Choice.none).reason == .choseNone)
        #expect(decision(headless, stored: .machine).reason == .machineLoginMissing)
        #expect(decision(.init(requested: .pass, byPerson: true, headless: true)).step == .install)
        #expect(decision(.init(requested: .pass, byPerson: false, headless: true)).step == .refuse, "an agent's --login pass is no consent")
        #expect(decision(.init(), stored: nil).step == .confirmThenInstall, "the palette still asks once")
        #expect(decision(headless).refusal == .needsLoginChoice)
        var codex = decision(headless)
        codex.harness = "codex"
        #expect(codex.refusal == nil, "a headless Codex start goes on as on base (cmux#34209 tracks refusing it)")
    }

    /// A rejected credential's automatic recovery never copies a login the run or the person refused.
    @Test func automaticRecoveryHonorsNoneAndMachine() {
        var decision = Decision(dogfood: true, setting: nil, harness: nil, signedIn: true)
        #expect(CloudHarnessLoginChoices.allowsAutomaticCopy(nil, stored: nil))
        #expect(CloudHarnessLoginChoices.allowsAutomaticCopy(nil, stored: .pass))
        #expect(!CloudHarnessLoginChoices.allowsAutomaticCopy(nil, stored: Decision.Choice.none))
        #expect(!CloudHarnessLoginChoices.allowsAutomaticCopy(nil, stored: .machine))
        decision.requested = Decision.Choice.none
        #expect(!CloudHarnessLoginChoices.allowsAutomaticCopy(decision, stored: .pass), "the run's --login none wins")
        decision.requested = .pass
        #expect(!CloudHarnessLoginChoices.allowsAutomaticCopy(decision, stored: nil), "an agent's --login pass is no consent")
        #expect(CloudHarnessLoginChoices.allowsAutomaticCopy(decision, stored: .pass))
        decision.requestedByPerson = true
        #expect(CloudHarnessLoginChoices.allowsAutomaticCopy(decision, stored: nil))
    }

    /// The person's own `--login` is kept per user; an agent's is used for that run only, and its
    /// `pass` never overrides a kept `none` or `machine`.
    @Test func onlyThePersonsChoiceIsKept() throws {
        let suite = "CloudStartChatLoginTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let choices = CloudHarnessLoginChoices(defaults: defaults)
        var decision = Decision(dogfood: true, setting: nil, harness: nil, signedIn: true)
        CloudHarnessLoginAsk(requested: .pass, byPerson: false, headless: true).apply(to: &decision, userID: "u1", choices: choices)
        #expect(decision.requested == .pass && !decision.requestedByPerson && decision.stored == nil)
        #expect(choices.load(userID: "u1") == nil)
        CloudHarnessLoginAsk(requested: .machine, byPerson: true, headless: true).apply(to: &decision, userID: "u1", choices: choices)
        #expect(decision.requestedByPerson && choices.load(userID: "u1") == .machine)
        CloudHarnessLoginAsk(headless: true).apply(to: &decision, userID: "u1", choices: choices)
        #expect(decision.requested == nil && decision.stored == .machine)
        CloudHarnessLoginAsk(requested: .pass, byPerson: false, headless: true).apply(to: &decision, userID: "u1", choices: choices)
        #expect(decision.requested == .machine, "an agent's pass never overrides the person's kept machine")
        choices.save(.none, userID: "u1")
        CloudHarnessLoginAsk(requested: .pass, byPerson: false, headless: true).apply(to: &decision, userID: "u1", choices: choices)
        #expect(decision.requested == Decision.Choice.none, "nor their kept none")
        #expect(choices.load(userID: "u2") == nil, "per user")
        #expect(throws: CloudHarnessLoginAsk.Invalid()) { try CloudHarnessLoginAsk.choice("always") }
        #expect(try CloudHarnessLoginAsk.choice(" NONE ") == Decision.Choice.none && CloudHarnessLoginAsk.choice(nil) == nil)
    }
}
