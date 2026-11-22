import CmuxNextCloud
import CmuxNextWakeupsTestSupport
import Observation
import Testing

/// A machine whose new link comes up before its handshake carries the capability.
@Observable @MainActor
private final class Relinking {
    var holdsTabs = false
}

/// How many times a start's update ran.
@MainActor
private final class UpdateRuns {
    var count = 0
}

/// The machine lacks what the start needs and could not be updated to it.
private struct MachineTooOld: Error {}

@Suite
@MainActor
struct CloudOutdatedMachineTests {
    @Test func anOutdatedMachineUpdatesBeforeItsCapabilityIsUsed() async {
        var handshake = "old"
        var holdsTabs = false
        var updates = 0

        await CloudOutdatedMachine.updateBeforeUsingCapability(
            holds: { holdsTabs },
            relink: .seconds(1),
            update: {
                updates += 1
                await Task.yield()
                handshake = "new"
                holdsTabs = true
                return true
            })

        #expect(updates == 1)
        #expect(handshake == "new")
        #expect(holdsTabs)
    }

    @Test func anUpdateThatDoesNotRelinkReturnsWithinTheBoundedWait() async {
        var holdsTabs = false
        var updates = 0

        await CloudOutdatedMachine.updateBeforeUsingCapability(
            holds: { holdsTabs },
            relink: .milliseconds(10),
            update: {
                updates += 1
                return true
            })

        #expect(updates == 1)
        #expect(!holdsTabs)
    }

    @Test func anAlreadyCurrentMachineDoesNotUpdate() async {
        var updates = 0

        await CloudOutdatedMachine.updateBeforeUsingCapability(
            holds: { true },
            relink: .milliseconds(10),
            update: {
                updates += 1
                return true
            })

        #expect(updates == 0)
    }

    @Test func aNewLinkWithoutTheCapabilityYetIsWaitedFor() async {
        let machine = Relinking()

        await CloudOutdatedMachine.updateBeforeUsingCapability(
            holds: { machine.holdsTabs },
            relink: .seconds(5),
            update: {
                // The link changed already; the capability arrives with the handshake a turn later.
                Task { @MainActor in machine.holdsTabs = true }
                return true
            })

        #expect(machine.holdsTabs)
    }

    /// A machine whose host updater never takes a build older than the one it applied: the start's update never ended,
    /// and the start waited 8 minutes, then failed with "Something went wrong" (2026-11-16). It goes on at the bound, and
    /// waits for no new link after it.
    @Test(.timeLimit(.minutes(1))) func anUpdateThatNeverEndsNoLongerHoldsTheStartPastItsBound() async throws {
        let clock = ManualClock()
        let runs = UpdateRuns()
        let (never, end) = AsyncStream<Void>.makeStream()
        defer { end.finish() }
        // task-owner: this test; awaited below
        let start = Task {
            await CloudOutdatedMachine.updateBeforeUsingCapability(holds: { false }, relink: .seconds(90), within: CloudOutdatedMachine.startUpdateWait, clock: clock) {
                runs.count += 1
                for await _ in never {}
                return true
            }
        }
        try await clock.waitForSleeper()
        clock.advance(by: CloudOutdatedMachine.startUpdateWait)
        await start.value

        #expect(runs.count == 1)
        #expect(CloudOutdatedMachine.startUpdateWait <= .seconds(90), "a start reads as stalled past a minute and a half")
        #expect(CloudOutdatedMachine.startUpdateRun < CloudOutdatedMachine.startUpdateWait, "the start's own run ends before the start stops waiting")
    }

    /// A refusal (the update ran and changed nothing: `update` false) ends the wait at once: no bound and no relink wait
    /// pass on the clock, which nothing advances. A start that needs the missing capability ends saying what is wrong.
    @Test(.timeLimit(.minutes(1))) func aRefusedUpdateEndsTheStartAtOnceWithWhatIsWrong() async {
        let clock = ManualClock()
        let runs = UpdateRuns()
        await #expect(throws: MachineTooOld.self) {
            try await CloudOutdatedMachine.requireCapability(holds: { false }, lacks: { true }, clock: clock, update: {
                runs.count += 1
                return false
            }, missing: MachineTooOld())
        }
        #expect(runs.count == 1)
        #expect(clock.now.offset == .zero)
    }

    /// A start whose machine lacks nothing it uses (no model connection chosen) goes on on the machine's own software
    /// after a refused or abandoned update, as the route check does for a machine that predates its report.
    @Test(.timeLimit(.minutes(1))) func aStartThatNeedsNothingMissingGoesOnAfterARefusal() async throws {
        let clock = ManualClock()
        try await CloudOutdatedMachine.requireCapability(holds: { false }, lacks: { false }, clock: clock, update: { false }, missing: MachineTooOld())
        #expect(clock.now.offset == .zero)
    }

    /// A machine that already serves the capability is neither updated nor refused.
    @Test(.timeLimit(.minutes(1))) func aMachineThatServesTheCapabilityIsNotUpdated() async throws {
        let runs = UpdateRuns()
        try await CloudOutdatedMachine.requireCapability(holds: { true }, lacks: { false }, clock: ManualClock(), update: {
            runs.count += 1
            return true
        }, missing: MachineTooOld())
        #expect(runs.count == 0)
    }
}
