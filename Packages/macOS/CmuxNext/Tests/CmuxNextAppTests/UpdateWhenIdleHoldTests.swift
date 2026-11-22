import Foundation
import CmuxNextTestSupport
@testable import CmuxNextUpdater
import CmuxNextWakeupsTestSupport
import Testing

/// Update When Idle (`updates.installWhenIdle`; Leo, 2026-11-19: "when it's idle, it's able to ... update
/// automatically ... maybe even having it as an opt-in option would be pretty interesting. Yeah, like
/// update when idle"): a staged update installs only once the idle gate clears, never mid-turn or over an
/// unsent draft, and the moment's own holds still come first.
@MainActor @Suite(.serialized) struct UpdateWhenIdleHoldTests {
    @MainActor private final class Gate {
        var reason: UpdateRelaunchMoment.Interruption? = .notIdle
    }

    @Test func theGateHoldsUntilItClears() async throws {
        let clock = ManualClock()
        let gate = Gate()
        let hold = UpdateRelaunchMomentHold(moment: { UpdateRelaunchMoment() }, clock: clock)
        hold.idleGate = { gate.reason }
        var installs = 0
        #expect(hold.hold { installs += 1 })
        #expect(hold.state?.reason == .notIdle)

        // Away long enough, but an agent turn runs: still held, with the new reason.
        gate.reason = .agentWorking
        try await clock.waitForSleeper()
        clock.advance(by: UpdateRelaunchMomentHold.recheckInterval)
        try await clock.waitForSleeper()
        #expect(installs == 0)
        #expect(hold.state?.reason == .agentWorking)

        // The turn ended; a draft is unsent.
        gate.reason = .unsentDraft
        clock.advance(by: UpdateRelaunchMomentHold.recheckInterval)
        try await clock.waitForSleeper()
        #expect(installs == 0)
        #expect(hold.state?.reason == .unsentDraft)

        gate.reason = nil
        clock.advance(by: UpdateRelaunchMomentHold.recheckInterval)
        for _ in 0..<1_000 where installs == 0 { await Task.yield() }
        #expect(installs == 1)
        #expect(!hold.isHolding)
    }

    /// The moment (a sheet) still holds even when the gate is clear.
    @Test func theMomentStillComesFirst() {
        let hold = UpdateRelaunchMomentHold(moment: { UpdateRelaunchMoment(sheet: true) }, clock: ManualClock())
        hold.idleGate = { nil }
        #expect(hold.hold {})
        #expect(hold.state?.reason == .sheet)
    }

    /// Without the setting (no gate) only the moment holds, as before.
    @Test func noGateIsTheOldBehavior() {
        let hold = UpdateRelaunchMomentHold(moment: { UpdateRelaunchMoment() }, clock: ManualClock())
        #expect(!hold.hold {})
    }

    /// The updater wires the gate only while the setting is on, and the gate is the App's.
    @Test func configureTurnsTheGateOnAndOff() {
        let updater = UpdaterService(enableSparkle: false, recordsUpdates: false)
        updater.idleInstallGate = { .notIdle }
        updater.configure(checkAutomatically: true, checkInterval: 3600, downloadAutomatically: false,
                          idleInstall: (600, 60), installWhenIdleMinutes: 15)
        #expect(updater.installWhenIdle == .seconds(900))
        #expect(updater.relaunchMomentHold.idleGate != nil)
        #expect(updater.relaunchMomentHold.surfaceAfter == .seconds(900))
        updater.configure(checkAutomatically: true, checkInterval: 3600, downloadAutomatically: false,
                          idleInstall: (600, 60), installWhenIdleMinutes: nil)
        #expect(updater.installWhenIdle == nil)
        #expect(updater.relaunchMomentHold.idleGate == nil)
        #expect(updater.relaunchMomentHold.surfaceAfter == .seconds(600))
    }
}
