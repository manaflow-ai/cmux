@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextEnergy
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
                                   lowPowerMode: lowPower) { seen.modes.append($0) }
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
                                   lowPowerMode: monitor.lowPowerMode) { seen.modes.append($0) }
        monitor.lowPowerMode.override = true
        #expect(seen.modes == [.plain])
        #expect(monitor.inputs.lowPowerMode)
        _ = watch
    }
}
