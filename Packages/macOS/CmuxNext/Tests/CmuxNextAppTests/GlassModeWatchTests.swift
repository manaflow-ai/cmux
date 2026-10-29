@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextEnergy
import CmuxNextWakeups
import Foundation
import Testing

/// The glass mode pages draw follows the energy monitor's Low Power Mode, its `debug.low_power_mode`
/// override included. p14-energy-021 first made `GlassLensMode.current` read the system flag, so the
/// override reached WebKit but pages kept lens glass and the watch never fired.
@MainActor
struct GlassModeWatchTests {
    final class Seen {
        var modes: [GlassLensMode] = []
    }

    static func lensStore() -> TunableStore {
        let store = TunableStore()
        store.register([GlassLensMode.tunable.descriptor])
        store.activate(file: nil)
        GlassLensMode.choose(.lens, in: store)
        return store
    }

    @Test func theLowPowerOverrideDrawsPlainGlassWhileTheSystemSaysOff() {
        let lowPower = LowPowerMode(enabled: false)
        let seen = Seen()
        let watch = GlassModeWatch(store: Self.lensStore(), reduceTransparency: ReduceTransparency(system: { false }),
                                   lowPowerMode: lowPower, mainWork: linklessMainWork()) { seen.modes.append($0) }
        #expect(watch.mode == .lens)
        lowPower.override = true
        #expect(seen.modes == [.plain])
        #expect(watch.mode == .plain)
        lowPower.override = nil
        #expect(seen.modes == [.plain, .lens])
    }

    @Test func theMonitorsLowPowerModeIsTheOneTheWatchFollows() {
        let monitor = EnergyMonitor(lowPowerMode: LowPowerMode(enabled: false), thermal: ThermalStateWatch(state: .nominal),
                                    power: PowerSourceInput(read: { PowerSourceReading() }, listen: { _ in }))
        let seen = Seen()
        let watch = GlassModeWatch(store: Self.lensStore(), reduceTransparency: ReduceTransparency(system: { false }),
                                   lowPowerMode: monitor.lowPowerMode, mainWork: linklessMainWork()) { seen.modes.append($0) }
        monitor.lowPowerMode.override = true
        #expect(seen.modes == [.plain])
        #expect(monitor.inputs.lowPowerMode)
        _ = watch
    }

    /// The glass tunable is a scheduled observation. A Debug choice applies as one posted
    /// `visible` task on the app's scheduler, not in the turn of the change and not as an unclassed main hop.
    @Test func aGlassChoiceAppliesAsOnePostedVisibleTask() {
        let store = Self.lensStore()
        let mainWork = linklessMainWork()
        let seen = Seen()
        let watch = GlassModeWatch(store: store, reduceTransparency: ReduceTransparency(system: { false }),
                                   lowPowerMode: LowPowerMode(enabled: false), mainWork: mainWork) { seen.modes.append($0) }
        GlassLensMode.choose(.plain, in: store)
        #expect(seen.modes.isEmpty, "nothing applies in the turn of the change")
        #expect(mainWork.postedCount(.visible) == 1, "one posted visible flush")
        #expect(runMainLoop { seen.modes == [.plain] }, "the posted flush applies the choice")
        #expect(watch.mode == .plain)
    }

    /// p06 rule 9, person: a person's Debug choice applies in the input-response pass, in the input's turn and before
    /// its commit, even while the person's next input is pending; its posted `visible` task then finds nothing to do.
    @Test func aPersonsGlassChoiceAppliesInTheInputResponsePassWhileInputIsPending() {
        let store = Self.lensStore()
        let harness = FollowerHarness()
        let seen = Seen()
        let watch = GlassModeWatch(store: store, reduceTransparency: ReduceTransparency(system: { false }),
                                   lowPowerMode: LowPowerMode(enabled: false), mainWork: harness.work) { seen.modes.append($0) }
        harness.input.pending = true
        harness.work.causes.withCause(.person) { GlassLensMode.choose(.plain, in: store) }
        #expect(seen.modes.isEmpty, "nothing applies inside the change")
        #expect(harness.work.causes.flushPersonCaused() == 1, "the pass applies the person's change")
        #expect(seen.modes == [.plain], "applied before the commit, with input pending")
        harness.frame()
        harness.frame()
        #expect(seen.modes == [.plain], "the pass flushed it: its visible task applies nothing more")
        #expect(watch.mode == .plain)
        harness.stop()
    }
}
