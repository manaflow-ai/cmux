import CmuxNextCloud
@testable import CmuxNextCloudCredentials
import Foundation
import Testing

/// A Cloud start's machine reads (cmuxterm-hq#8060: the span from the create to the harness login line is 15.7 s at p50):
/// the guest's kind and the machine's own Claude login go out together, not one round trip after the other; a start
/// racing a spare warm's copy reads the login only after that copy; and nothing is read on a machine the caller does
/// not own. A read that ran one after the other never meets its partner here, so the suite's time limit fails it.
@Suite(.timeLimit(.minutes(1)))
struct CloudStartMachineReadTests {
    typealias Decision = CloudHarnessLoginDecision
    nonisolated static let none = Decision.MachineProbe(exitCode: 0, stdout: "none\n")

    /// Two reads that each wait until the other has begun: they finish only when they run at once.
    actor Meet {
        var arrived: Set<String> = [], waiting: [CheckedContinuation<Void, Never>] = [], order: [String] = []
        func arrive(_ name: String, waitFor other: String) async {
            arrived.insert(name); order.append(name)
            for waiter in waiting { waiter.resume() }
            waiting = []
            while !arrived.contains(other) { await withCheckedContinuation { waiting.append($0) } }
        }
        func note(_ name: String) { order.append(name) }
    }

    static func owned() -> Decision {
        var start = Decision(dogfood: true, setting: nil, harness: "claude", signedIn: true)
        start.callerOwns = true
        return start
    }

    @Test func theGuestAndTheLoginAreReadAtOnce() async throws {
        var start = Self.owned()
        let meet = Meet()
        try await start.readMachine(exec: { _ in await meet.arrive("guest", waitFor: "login"); return "vm-kind:owner\n" }, pause: {},
                                    clock: ContinuousClock(), login: { await meet.arrive("login", waitFor: "guest"); return (Self.none, true) },
                                    waitCopy: {})
        #expect(start.guestKind == "owner" && start.guestTakesLogin)
        #expect(start.machineLogin == nil && start.machineProbe == Self.none && start.cached)
        #expect(start.step == .confirmThenInstall || start.step == .install)
    }

    /// The warm's copy is what the login read would find: the login waits for it, the guest read does not.
    @Test func theLoginIsReadOnlyAfterAWarmCopy() async throws {
        var start = Self.owned()
        let meet = Meet()
        try await start.readMachine(exec: { _ in await meet.arrive("guest", waitFor: "copy"); return "vm-kind:owner\n" }, pause: {},
                                    clock: ContinuousClock(), login: { await meet.note("login"); return (Self.none, true) },
                                    waitCopy: { await meet.arrive("copy", waitFor: "guest") })
        let order = await meet.order
        #expect(order.firstIndex(of: "copy")! < order.firstIndex(of: "login")!)
        #expect(start.guestTakesLogin && start.machineProbe == Self.none)
    }

    /// A guest that does not take the caller's login (no kind read: the exec failed) keeps no login read.
    @Test func aGuestThatTakesNoLoginKeepsNoLoginRead() async throws {
        var start = Self.owned()
        try await start.readMachine(exec: { _ in nil }, pause: {}, clock: ContinuousClock(),
                                    login: { (Self.none, true) }, waitCopy: {})
        #expect(!start.guestTakesLogin && start.machineProbe == nil && !start.cached)
    }

    /// Not the caller's machine (the platform said so): nothing is read on it.
    @Test func aMachineNotTheCallersIsNotRead() async throws {
        var start = Self.owned()
        start.callerOwns = false
        let meet = Meet()
        try await start.readMachine(exec: { _ in await meet.note("guest"); return "vm-kind:owner\n" }, pause: {}, clock: ContinuousClock(),
                                    login: { await meet.note("login"); return (Self.none, true) }, waitCopy: { await meet.note("copy") })
        #expect(await meet.order.isEmpty && start.guestStdout == nil && start.machineProbe == nil)
    }

    /// The step lines the chat probe reads (`select_marks_ms`): a name and whole milliseconds, never negative; each
    /// step runs from the end of the one before it, so the steps add up to the span.
    @MainActor @Test func aStepLineIsItsNameAndWholeMillisecondsSinceTheStepBefore() {
        #expect(CloudStartSteps.line("login.machine", .milliseconds(1234) + .microseconds(900)) == "cloud start step: login.machine 1234 ms")
        #expect(CloudStartSteps.line("connect", .seconds(15)) == "cloud start step: connect 15000 ms")
        #expect(CloudStartSteps.line("tab", .milliseconds(-5)) == "cloud start step: tab 0 ms")
        var lines: [String] = [], now = ContinuousClock.now
        let steps = CloudStartSteps(log: { lines.append($0) }, now: { now })
        now += .milliseconds(40)
        steps.done("connect")
        now += .milliseconds(2500)
        steps.done("login")
        steps.done("approvals")
        #expect(lines == ["cloud start step: connect 40 ms", "cloud start step: login 2500 ms", "cloud start step: approvals 0 ms"])
        // The same steps, for the start's answer (`stages_ms`): `cmux cloud start-chat` lists them under its step.
        #expect(steps.recorded.map(\.step) == ["connect", "login", "approvals"])
        #expect(steps.recorded.map(\.ms) == [40, 2500, 0])
    }

    /// `cloud start-session`'s `stages_ms` (Leo, 2026-11-10: "have we figured out where the 26.5 seconds were yet?"):
    /// every clock made while the run's record is current adds its steps there in the order they end, a nested clock's
    /// (`login.machine`) before the step that holds it; a clock made outside the run only logs.
    @MainActor @Test func aRunsRecordHoldsEveryNestedClocksStepsInTheOrderTheyEnded() async {
        var now = ContinuousClock.now
        let record = CloudStartStepRecord()
        await CloudStartStepRecord.$current.withValue(record) {
            let outer = CloudStartSteps(log: { _ in }, now: { now })
            now += .milliseconds(7100)
            outer.done("machine")
            let login = CloudStartSteps(log: { _ in }, now: { now })
            now += .milliseconds(300)
            login.done("login.machine")
            now += .milliseconds(1200)
            login.done("login.transfer")
            outer.done("login")
        }
        CloudStartSteps(log: { _ in }, now: { now }).done("outside")
        #expect(record.steps.map(\.name) == ["machine", "login.machine", "login.transfer", "login"])
        #expect(record.steps.map(\.ms) == [7100, 300, 1200, 1500])
    }
}
