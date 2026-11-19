@testable import CmuxNextApp
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

    private actor Log {
        var events: [String] = []
        func add(_ event: String) { events.append(event) }
    }

    /// `cloud start-session` on a machine it made (prod, app 01fc64af: a 19 s keyed start after an 18 s connect): the keyed restart
    /// begins with the connect, not after it, runs once, and the start goes on only once it ended.
    @MainActor @Test(.timeLimit(.minutes(1))) func aMadeMachinesApprovalsBeginWithTheConnect() async throws {
        let log = Log(), (began, beginning) = AsyncStream<Void>.makeStream()
        let folder = try await CloudStartSession.approvalsBesideConnect(made: true, early: {
            await log.add("early"); beginning.yield(); await Task.yield(); await log.add("keyed"); return true
        }, approvals: { await log.add("again"); return true }) {
            for await _ in began { break } // the connect ends only once the keyed restart began: never before it
            await log.add("connected")
        } folder: { await log.add("folder"); return "/root" }
        let events = await log.events
        #expect(folder == "/root")
        #expect(events.first == "early")
        #expect(events.contains("keyed"), "awaited before the start went on: \(events)")
        #expect(!events.contains("again"), "a machine keyed beside the connect is not restarted again: \(events)")
    }

    /// A first try that keyed nothing (the new VM not up yet) is tried again once the connect ended, and awaited.
    @MainActor @Test func aMadeMachineThatKeyedNothingIsTriedAgainAfterTheConnect() async throws {
        let log = Log()
        _ = try await CloudStartSession.approvalsBesideConnect(made: true, early: { await log.add("early"); return false }, approvals: { await log.add("again"); return true }) {
            await Task.yield()
            await log.add("connected")
        } folder: { 0 }
        let events = await log.events
        let connected = try #require(events.firstIndex(of: "connected")), again = try #require(events.firstIndex(of: "again"), "awaited before the start went on: \(events)")
        #expect(connected < again)
        #expect(events.filter { $0 == "again" }.count == 1)
    }

    private struct ConnectFailed: Error {}

    /// A connect that throws (an account change, a machine that never linked) cancels the made machine's keyed restart and awaits
    /// it before the start ends, so the start gate is never released under it; nothing is tried again.
    @MainActor @Test func aConnectThatThrowsCancelsAndAwaitsTheMadeMachinesApprovals() async {
        let prep = Prep(), log = Log()
        await #expect(throws: ConnectFailed.self) {
            try await CloudStartSession.approvalsBesideConnect(made: true, early: {
                try? await Task.sleep(for: .seconds(30)) // a machine not running yet; the cancel ends the wait at once
                await prep.end(cancelled: Task.isCancelled)
                return false
            }, approvals: { await log.add("again"); return true }) {
                await Task.yield()
                throw ConnectFailed()
            } folder: { 0 }
        }
        #expect(await prep.ended, "the prep ended before the start did")
        #expect(await prep.cancelled)
        #expect(await log.events.isEmpty, "nothing restarts after a failed connect")
    }

    /// A taken machine may be paused and runs someone's agent: its status-read restart begins only after the connect, as before.
    @MainActor @Test func aTakenMachinesApprovalsBeginAfterTheConnect() async throws {
        let log = Log()
        _ = try await CloudStartSession.approvalsBesideConnect(made: false, early: { await log.add("early"); return true }, approvals: { await log.add("approvals"); return true }) {
            await Task.yield()
            await log.add("connected")
        } folder: { 0 }
        #expect(await log.events == ["connected", "approvals"])
    }
}
