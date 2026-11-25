import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextRemote
import Foundation
import Testing

/// Cloud's pre-chat approval preparation follows the same typed safe-to-restart signal as the
/// remote daemon start. Failures stay on the unkeyed start path so a busy or shared machine can
/// still show its normal restart notice.
@Suite(.serialized)
struct CloudApprovalsPrepareTests {
    private actor Counter {
        var value = 0

        func increment() { value += 1 }
        func read() -> Int { value }
    }

    @Test func anIdleMachineRunsTheKeyedStartOnce() async {
        let machine = "cloud-approvals-idle-\(UUID().uuidString)"
        let starts = Counter()
        let prepared = await RemoteApprovalPreparations.shared.prepare(
            machine: machine,
            daemonSaidSafe: true, held: false,
            idle: { true },
            restart: {
                await starts.increment()
                return true
            })

        #expect(prepared)
        #expect(await starts.read() == 1)
    }

    @Test func aBusyMachineDoesNotRestart() async {
        let machine = "cloud-approvals-busy-\(UUID().uuidString)"
        let starts = Counter()
        let prepared = await RemoteApprovalPreparations.shared.prepare(
            machine: machine,
            daemonSaidSafe: false, held: false,
            idle: { false },
            restart: {
                await starts.increment()
                return true
            })

        #expect(!prepared)
        #expect(await starts.read() == 0)
    }

    /// A start's early read beside its connect (`cacheBusy: false`) keeps no busy answer: the read after the connect asks
    /// again and keys a daemon that went idle meanwhile, where a kept answer would start the chat unkeyed for a minute.
    @Test func anEarlyBusyReadIsAskedAgainAfterTheConnect() async {
        let machine = "cloud-approvals-early-\(UUID().uuidString)"
        let starts = Counter(), reads = Counter()
        let early = await RemoteApprovalPreparations.shared.prepare(
            machine: machine, daemonSaidSafe: false, held: false,
            idle: { await reads.increment(); return false },
            restart: { await starts.increment(); return true }, cacheBusy: false)
        let after = await RemoteApprovalPreparations.shared.prepare(
            machine: machine, daemonSaidSafe: false, held: false,
            idle: { await reads.increment(); return true },
            restart: { await starts.increment(); return true })

        #expect(!early)
        #expect(after)
        #expect(await reads.read() == 2)
        #expect(await starts.read() == 1)
    }

    /// The kept answer (the default): a second start within the minute reads nothing and starts unkeyed.
    @Test func aKeptBusyAnswerIsNotReadAgain() async {
        let machine = "cloud-approvals-kept-\(UUID().uuidString)"
        let reads = Counter()
        _ = await RemoteApprovalPreparations.shared.prepare(
            machine: machine, daemonSaidSafe: false, held: false,
            idle: { await reads.increment(); return false }, restart: { true })
        let again = await RemoteApprovalPreparations.shared.prepare(
            machine: machine, daemonSaidSafe: false, held: false,
            idle: { await reads.increment(); return true }, restart: { true })

        #expect(!again)
        #expect(await reads.read() == 1)
    }

    @Test func aKeyedStartFailureFallsBackWithoutThrowing() async {
        let machine = "cloud-approvals-failure-\(UUID().uuidString)"
        let starts = Counter()
        let prepared = await RemoteApprovalPreparations.shared.prepare(
            machine: machine,
            daemonSaidSafe: true, held: false,
            idle: { true },
            restart: {
                await starts.increment()
                return false
            })

        #expect(!prepared)
        #expect(await starts.read() == 1)
    }

    /// A start turning approvals on ahead of its chat, on a machine whose run already holds this app's key: nothing restarts.
    @Test func aMachineThatHoldsTheKeyIsNotRestartedAgain() async {
        let machine = "cloud-approvals-held-\(UUID().uuidString)"
        let starts = Counter()
        let prepared = await RemoteApprovalPreparations.shared.prepare(machine: machine, daemonSaidSafe: false, held: true, idle: { true }) {
            await starts.increment()
            return true
        }
        #expect(prepared)
        #expect(await starts.read() == 0)
    }

    /// A start that finds another's preparation in flight (a warm spare's key-ahead) waits its budget, not the preparation.
    @Test func aJoinerWaitsOnlyItsBudgetOnAnotherPreparation() async {
        let machine = "cloud-approvals-join-\(UUID().uuidString)"
        let slow = Task { await RemoteApprovalPreparations.shared.run(machine: machine, keepBusy: false) { try? await Task.sleep(for: .seconds(3)); return true } }
        try? await Task.sleep(for: .milliseconds(100))
        let began = ContinuousClock.now
        let joined = await RemoteApprovalPreparations.shared.prepare(machine: machine, daemonSaidSafe: true, held: false, joinBudget: .milliseconds(200), idle: { true }, restart: { true })
        #expect(!joined)
        #expect(ContinuousClock.now - began < .seconds(2))
        #expect(await slow.value) // the owner's preparation was not cancelled
    }

    /// A start gave up on a preparation still reading status: that preparation restarts nothing after (the chat is on it).
    @Test func aPreparationAStartGaveUpOnDoesNotRestart() async {
        let machine = "cloud-approvals-gaveup-\(UUID().uuidString)"
        let restarts = Counter()
        let owner = Task { await RemoteApprovalPreparations.shared.prepare(machine: machine, daemonSaidSafe: false, held: false,
            idle: { try? await Task.sleep(for: .seconds(1)); return true }, restart: { await restarts.increment(); return true }) }
        try? await Task.sleep(for: .milliseconds(100))
        let joined = await RemoteApprovalPreparations.shared.prepare(machine: machine, daemonSaidSafe: false, held: false, joinBudget: .milliseconds(200),
                                                                     idle: { true }, restart: { true })
        #expect(!joined)
        #expect(await owner.value == false)
        #expect(await restarts.read() == 0)
    }

    /// A start that joins a preparation already in its keyed restart waits it out: a chat started then would die with the daemon.
    @Test func aStartWaitsOutARestartThatBegan() async {
        let machine = "cloud-approvals-restarting-\(UUID().uuidString)"
        let owner = Task { await RemoteApprovalPreparations.shared.prepare(machine: machine, daemonSaidSafe: true, held: false,
            idle: { true }, restart: { try? await Task.sleep(for: .seconds(1)); return true }) }
        try? await Task.sleep(for: .milliseconds(100))
        let joined = await RemoteApprovalPreparations.shared.prepare(machine: machine, daemonSaidSafe: true, held: false, joinBudget: .milliseconds(200),
                                                                     idle: { true }, restart: { true })
        #expect(joined)
        #expect(await owner.value)
    }

    @Test func aStatusReadPastItsBudgetGivesNoAnswer() async {
        let idle: Bool? = await RemoteApprovalPreparations.bounded(.milliseconds(100)) { try? await Task.sleep(for: .seconds(5)); return true }
        #expect(idle == nil)
        let quick: Bool? = await RemoteApprovalPreparations.bounded(.seconds(5)) { true }
        #expect(quick == true)
    }

    /// The daemon refuses a keyed start as safe to restart: a Cloud start (`restartsInStart` false) goes unkeyed with no 15 s restart.
    @Test(arguments: [false, true])
    func aCloudStartNeverRunsTheKeyedRestartInTheStartStep(restartsInStart: Bool) async throws {
        let prepared = Counter(), starts = Counter()
        let machine = "cloud-approvals-coordinator-\(UUID().uuidString)"
        let approvals = AgentPaneRemoteApprovals(machineID: machine, label: "m", restart: { nil }, prepare: { _ in await prepared.increment(); return true })
        let started: String = try await AgentRemoteStartCoordinator(approvals: approvals, servesKeyedReason: true, restartsInStart: restartsInStart)
            .keyedStart(nil, nil, nil, proceed: {}, start: { _, _, _, key in
                await starts.increment()
                if key != nil { throw AgentRemoteStartRefusal(code: AgentSessionAttachError.needsKeyedStart, machine: machine, keyedRestartSafe: true) }
                return "unkeyed"
            })
        #expect(started == "unkeyed")
        #expect(await prepared.read() == (restartsInStart ? 1 : 0))
        #expect(await starts.read() == 2)
    }

    private actor Prep {
        var ended = false, cancelled = false
        func end(cancelled: Bool) { (ended, self.cancelled) = (true, cancelled) }
    }

    private struct LoginFailed: Error {}

    /// #39069's review: a start whose login threw (an account change) left its approvals prep running past the start's
    /// end, so the start gate was released under a restart. The start owns the prep: cancelled and awaited first.
    @MainActor @Test func aFailedLoginCancelsAndAwaitsThePrepBeforeTheStartEnds() async {
        let prep = Prep()
        await #expect(throws: LoginFailed.self) {
            try await RemoteApprovalPreparations.owned({
                try? await Task.sleep(for: .seconds(30)) // a slow status read; the cancel ends it at once
                await prep.end(cancelled: Task.isCancelled)
                return false
            }) {
                await Task.yield()
                throw LoginFailed()
            }
        }
        #expect(await prep.ended, "the prep ended before the start did")
        #expect(await prep.cancelled, "the prep saw the start's cancel, so it restarts nothing")
    }

    /// A login that passes waits for the prep too, uncancelled: the chat's first start carries the key.
    @MainActor @Test func aPassedLoginAwaitsThePrepUncancelled() async throws {
        let prep = Prep()
        let value = try await RemoteApprovalPreparations.owned({
            await Task.yield()
            await prep.end(cancelled: Task.isCancelled)
            return true
        }) { 7 }
        #expect(value == 7)
        #expect(await prep.ended)
        #expect(await !prep.cancelled)
    }

    /// cmux#54460's overlap: a failed connect cancels and awaits the early prep before the start ends, and runs no later one.
    @MainActor @Test func aFailedConnectCancelsAndAwaitsTheEarlyPrep() async {
        let prep = Prep(), later = Counter()
        await #expect(throws: LoginFailed.self) {
            try await RemoteApprovalPreparations.owned(early: true, connect: { await Task.yield(); throw LoginFailed() }, prepare: { early in
                guard early else { await later.increment(); return true }
                try? await Task.sleep(for: .seconds(30))
                await prep.end(cancelled: Task.isCancelled)
                return false
            }) { 7 }
        }
        #expect(await prep.ended)
        #expect(await prep.cancelled)
        #expect(await later.read() == 0)
    }

    /// The early prep's yes stands; its no (or no early prep) runs the later one beside the body.
    @MainActor @Test(arguments: [true, false]) func theLaterPrepRunsOnlyWhenTheEarlyOneSaidNo(earlyAnswer: Bool) async throws {
        let later = Counter(), order = Counter()
        let value = try await RemoteApprovalPreparations.owned(early: true, connect: { await Task.yield() }, prepare: { early in
            if early { await order.increment(); return earlyAnswer }
            await later.increment(); return true
        }) { 7 }
        #expect(value == 7)
        #expect(await order.read() == 1)
        #expect(await later.read() == (earlyAnswer ? 0 : 1))
        let none = Counter()
        _ = try await RemoteApprovalPreparations.owned(early: false, connect: {}, prepare: { early in #expect(!early); await none.increment(); return true }) { 0 }
        #expect(await none.read() == 1)
    }
}
