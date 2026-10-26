@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextEnergy
import CmuxNextKeepAwake
import Foundation
import Testing

/// `AppServices.startEnergy` pushes the energy monitor's inputs below the App: Low Power Mode to WebKit's
/// render rate and the video wallpaper, the power source to KeepAwake's battery rule, the thermal state to
/// the video wallpaper. A fake power source drives the monitor; the test's own KeepAwake and players
/// stand in for the app's.
@MainActor @Suite(.serialized)
struct EnergyConsumersTests {
    @MainActor final class FakePower {
        var reading = PowerSourceReading(hasBattery: true, batteryPercent: 90)
        var reads = 0
        var changed: (@MainActor () -> Void)?

        var input: PowerSourceInput {
            PowerSourceInput(read: {
                self.reads += 1
                return self.reading
            }, listen: { self.changed = $0 })
        }

        func change(onBattery: Bool) {
            reading.onBattery = onBattery
            changed?()
        }
    }

    static func monitor(_ power: FakePower) -> EnergyMonitor {
        EnergyMonitor(lowPowerMode: LowPowerMode(enabled: false), thermal: ThermalStateWatch(state: .nominal), power: power.input)
    }

    @Test func monitorChangesReachWebKitKeepAwakeAndTheVideoWallpaper() {
        let power = FakePower()
        let monitor = Self.monitor(power)
        let services = AppServices(environment: AppEnvironment.current([:]), energyMonitor: monitor)
        let keepAwake = KeepAwakeService(), videos = BackdropVideoPlayers()
        keepAwake.setPhoneServing(true)
        services.startEnergy(keepAwake: keepAwake, videos: videos)
        #expect(keepAwake.isHolding, "phone access does not hold on adapter power")
        #expect(!services.cache.webKit.lowPowerMode && !videos.lowPowerMode)

        power.change(onBattery: true)
        #expect(!keepAwake.isHolding, "KeepAwake kept the phone hold on battery")
        monitor.lowPowerMode.override = true
        #expect(services.cache.webKit.lowPowerMode, "WebKit did not take the debug Low Power Mode")
        #expect(videos.lowPowerMode)
        monitor.thermal.override = .serious
        #expect(videos.thermalState == .serious)

        power.change(onBattery: false)
        monitor.lowPowerMode.override = nil
        #expect(keepAwake.isHolding)
        #expect(!services.cache.webKit.lowPowerMode)
        keepAwake.setPhoneServing(false)
    }

    /// An `AppServices` a test builds never starts its monitor: no IOKit read, no power-source
    /// notification and no write to the app's KeepAwake.
    @Test func servicesBuiltForATestLeaveThePowerSourceAlone() {
        let power = FakePower()
        let monitor = Self.monitor(power)
        let services = AppServices(environment: AppEnvironment.current([:]), energyMonitor: monitor)
        #expect(services.energyMonitor === monitor)
        #expect(power.reads == 0 && power.changed == nil && services.energyLink == nil)
    }
}
