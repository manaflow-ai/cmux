import Foundation
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextApp

/// Settings > Updates' "Other machines" row: a machine that could not update in place has an
/// Update button. Its click (``DaemonUpdateBoard/update(_:retry:)`` with the policy's
/// ``DaemonUpdatePolicy/retry(_:)``) runs that machine's update again, past what the ledger and
/// this run remember, and its line says it is updating until the update ends.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudMachineUpdateButtonTests {
    static let unsupported = CloudMoveCLI.Answer(ok: false, errorCode: "machine_update_unsupported", error: "too old to update in place (no fs-v1)")
    static let id = CloudMachineUpdateTarget.id("vm-1")

    /// Leo's tidy-yellow-tern: it said it cannot update before this app could update it through
    /// exec, and the ledger keeps that, so no offer asks it again. One click does: it updates,
    /// and leaves the row.
    @Test func oneClickUpdatesAMachineThatCouldNotUpdate() async throws {
        let machine = FakeCloudMachine(build: CloudMachineUpdateTargetTests.older, level: .limited,
                                       answers: [Self.unsupported, Self.unsupported])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        let policy = fixture.policy(machine)
        await policy.offer(fixture.target(machine))
        await policy.drained()
        #expect(fixture.board.otherMachines?.machines == [DaemonUpdateBoard.OtherMachine(id: Self.id, line: CloudMachineUpdateStrings.unsupported("Leo VM"), canUpdate: true)])

        // This app can now update it through exec; an offer alone still does not ask it again.
        machine.allowLegacy([CloudMoveCLI.Answer(ok: true, updated: true, build: CloudMachineUpdateTargetTests.bundled)])
        await policy.offer(fixture.target(machine))
        await policy.drained()
        #expect(machine.updates == 1)

        #expect(await fixture.board.update(Self.id) { await policy.retry($0) })
        await policy.drained()
        #expect(machine.updates == 2)
        #expect(machine.legacyUpdates == 1)
        #expect(fixture.states.suffix(2) == [.updating, .updated(build: CloudMachineUpdateTargetTests.bundled)])
        #expect(fixture.board.otherMachines == nil, "an updated machine is still in the row")
        #expect(fixture.notices.isEmpty)
    }

    /// A machine repaired by hand since it said it cannot update: the click finds nothing to do,
    /// and its line goes rather than staying with its button.
    @Test func aClickOnARepairedMachineClearsItsLine() async throws {
        let machine = FakeCloudMachine(build: CloudMachineUpdateTargetTests.older, level: .limited, answers: [Self.unsupported])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        let policy = fixture.policy(machine)
        await policy.offer(fixture.target(machine))
        await policy.drained()
        machine.repair(build: CloudMachineUpdateTargetTests.bundled)

        #expect(await fixture.board.update(Self.id) { await policy.retry($0) })
        await policy.drained()
        #expect(machine.updates == 1, "a repaired machine updated again")
        #expect(fixture.board.otherMachines == nil)
    }

    /// A machine of unknown build (the app refused its daemon) that could not update, repaired
    /// since: the click finds nothing to do, and its line goes.
    @Test func aClickOnARepairedMachineOfUnknownBuildClearsItsLine() async throws {
        let machine = FakeCloudMachine(build: nil, level: .incompatible, answers: [Self.unsupported])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        let policy = fixture.policy(machine)
        await policy.offer(fixture.target(machine))
        await policy.drained()
        #expect(fixture.board.otherMachines?.machines.first?.canUpdate == true)
        machine.repair(build: CloudMachineUpdateTargetTests.bundled)

        #expect(await fixture.board.update(Self.id) { await policy.retry($0) })
        await policy.drained()
        #expect(machine.updates == 1)
        #expect(fixture.board.otherMachines == nil, "a repaired machine keeps its cannot-update line")
    }

    /// A click while the machine's turn reads it (before any update runs, so its line still has
    /// the button) is not lost: once that turn ends, the machine updates, once.
    @Test func aClickWhileItsTurnReadsTheMachineIsNotLost() async throws {
        let machine = FakeCloudMachine(build: CloudMachineUpdateTargetTests.older, level: .limited,
                                       answers: [Self.unsupported, Self.unsupported])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        let policy = fixture.policy(machine)
        await policy.offer(fixture.target(machine))
        await policy.drained()
        machine.allowLegacy([CloudMoveCLI.Answer(ok: true, updated: true, build: CloudMachineUpdateTargetTests.bundled)])

        // The offer reads the machine once (`urgent`); its turn's first read waits at the gate.
        let gate = DaemonReadGate(holding: 2)
        // The update the click asks for waits here, so its line can be read while it runs.
        let updating = DaemonReadGate(holding: 1)
        var source = machine.source
        let read = source.daemon
        let update = source.update
        source.daemon = { await gate.pass(); return await read() }
        source.update = { await updating.pass(); return try await update() }
        await policy.offer(CloudMachineUpdateTarget(machineID: "vm-1", displayName: "Leo VM", source: source, enabled: { true }))
        await gate.entered()
        #expect(await fixture.board.update(Self.id) { await policy.retry($0) })
        gate.release()
        await updating.entered()
        #expect(fixture.board.otherMachines?.machines
            == [DaemonUpdateBoard.OtherMachine(id: Self.id, line: DaemonUpdateBoard.updatingLine("Leo VM"), canUpdate: false)],
            "the clicked machine says it is updating while its update runs")
        updating.release()
        await policy.drained()

        #expect(machine.updates == 2)
        #expect(machine.legacyUpdates == 1)
        #expect(fixture.board.otherMachines == nil)
    }

    /// No target of that id in this run, or updates of other machines off: the click is refused.
    @Test func aClickOnAMachineThePolicyDoesNotKnowIsRefused() async throws {
        let machine = FakeCloudMachine(build: CloudMachineUpdateTargetTests.older, level: .limited, answers: [Self.unsupported])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        let policy = fixture.policy(machine)
        #expect(await policy.retry(Self.id) == false)
        #expect(machine.updates == 0)
    }

    /// While a clicked machine updates, its line says so with no button; a machine updating on
    /// its own (no click) is not added to the row. Refused clicks change nothing.
    @Test func aClickedMachineSaysItIsUpdatingUntilItEnds() async {
        let board = DaemonUpdateBoard()
        board.showNotice = { _ in nil }
        let tooOld = "tidy-yellow-tern runs a cmux too old to update in place."
        board.apply(DaemonUpdateEvent(id: "cloud:a", displayName: "tidy-yellow-tern", state: .cannotUpdate(reason: tooOld)))
        board.apply(DaemonUpdateEvent(id: "cloud:b", displayName: "fs-peer-1", state: .updating))
        #expect(board.otherMachines?.machines == [DaemonUpdateBoard.OtherMachine(id: "cloud:a", line: tooOld, canUpdate: true)])

        #expect(await board.update("cloud:a") { _ in false } == false)
        #expect(await board.update("cloud:b") { _ in true } == false, "only a machine that cannot update has the button")
        #expect(await board.update("cloud:a") { _ in true })
        board.apply(DaemonUpdateEvent(id: "cloud:a", displayName: "tidy-yellow-tern", state: .updating))
        #expect(board.otherMachines?.machines == [DaemonUpdateBoard.OtherMachine(id: "cloud:a", line: DaemonUpdateBoard.updatingLine("tidy-yellow-tern"), canUpdate: false)])
        board.apply(DaemonUpdateEvent(id: "cloud:a", displayName: "tidy-yellow-tern", state: .updated(build: "abc123def456")))
        #expect(board.otherMachines == nil)

        // The row as the page gets it: the id on the line with the button only.
        board.apply(DaemonUpdateEvent(id: "cloud:a", displayName: "tidy-yellow-tern", state: .cannotUpdate(reason: tooOld)))
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:x", displayName: "x", state: .failed(reason: "disk full", rolledBack: false)))
        let row = PageFactory.otherMachines(board)
        #expect(row?.updates == ["cloud:a", nil])
        #expect(row?.updateLabel == DaemonUpdateBoard.updateLabel)
    }
}

/// Holds the `holding`-th read of a machine's daemon until ``release()``; ``entered()`` returns once
/// that read waits.
nonisolated final class DaemonReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private let holding: Int
    private var held: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    init(holding: Int) { self.holding = holding }

    func pass() async {
        let hold = lock.withLock { reads += 1; return reads == holding && !released }
        guard hold else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                held = continuation
                defer { waiter = nil }
                return waiter
            }
            waiting?.resume()
        }
    }

    func entered() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if held != nil { return true }
                waiter = continuation
                return false
            }
            if now { continuation.resume() }
        }
    }

    func release() {
        lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { held = nil }
            return held
        }?.resume()
    }
}
