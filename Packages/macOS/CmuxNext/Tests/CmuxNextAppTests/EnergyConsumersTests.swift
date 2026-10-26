@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextEnergy
import CmuxNextKeepAwake
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// `AppServices.startEnergy` pushes the energy monitor's inputs below the App: Low Power Mode to the video
/// wallpaper, the power source to KeepAwake's battery rule, the thermal state to the video wallpaper.
/// WebKit's render rate follows the app's Energy Saver policy (`mainWork.energy`) itself. A fake power
/// source drives the monitor; the test's own KeepAwake and players stand in for the app's.
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

    @Test func monitorChangesReachKeepAwakeAndTheVideoWallpaper() {
        let power = FakePower()
        let monitor = Self.monitor(power)
        let services = AppServices(environment: AppEnvironment.current([:]), energyMonitor: monitor)
        let keepAwake = KeepAwakeService(), videos = BackdropVideoPlayers()
        keepAwake.setPhoneServing(true)
        services.startEnergy(keepAwake: keepAwake, videos: videos)
        #expect(keepAwake.isHolding, "phone access does not hold on adapter power")
        #expect(!videos.lowPowerMode)

        power.change(onBattery: true)
        #expect(!keepAwake.isHolding, "KeepAwake kept the phone hold on battery")
        monitor.lowPowerMode.override = true
        #expect(videos.lowPowerMode)
        monitor.thermal.override = .serious
        #expect(videos.thermalState == .serious)

        power.change(onBattery: false)
        monitor.lowPowerMode.override = nil
        #expect(keepAwake.isHolding)
        keepAwake.setPhoneServing(false)
    }

    /// The app's WebKit engine reads the app's one policy source (`mainWork.energy`), not the monitor's
    /// Low Power Mode: the saver turns its render rate down, and turning it off restores it.
    @Test func theAppsWebKitFollowsTheEnergySaverPolicy() {
        let services = AppServices(environment: AppEnvironment.current([:]), energyMonitor: Self.monitor(FakePower()))
        #expect(!services.cache.webKit.energySaver)
        services.mainWork.energy.update(EnergyPolicy(saverReason: .lowPowerMode))
        #expect(services.cache.webKit.energySaver, "the app's WebKit engine does not follow mainWork.energy")
        services.mainWork.energy.update(.normal)
        #expect(!services.cache.webKit.energySaver)
    }

    /// The `energySaver` feature is off by default: macOS Low Power Mode still reaches WebKit's render rate
    /// and the neighbor tabs, from the monitor through the driver, as it did before Energy Saver existed.
    /// The `energy.saver` setting does not change that while the feature is off.
    @Test func lowPowerModeStillReachesThePagesWhileTheFeatureIsOff() {
        let monitor = Self.monitor(FakePower())
        let services = AppServices(environment: AppEnvironment.current([:]), energyMonitor: monitor)
        guard !services.energy.driver.isEnabled else { return }  // a local Labs override turned the feature on
        let hibernation = BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry(), deadlines: services.mainDeadlines,
                                             energy: services.mainWork.energy)
        hibernation.apply(BrowserHibernationSetting(mode: .off, freezeSeconds: nil, neighborRadius: 1))
        hibernation.start()
        defer { hibernation.stop() }
        services.startEnergy(keepAwake: KeepAwakeService(), videos: BackdropVideoPlayers())
        services.energy.driver.update(setting: .off)
        #expect(!services.cache.webKit.energySaver && hibernation.neighborRadius == 1)

        monitor.lowPowerMode.override = true
        #expect(services.mainWork.energy.policy.lowPowerFallback && !services.mainWork.energy.policy.isSaver)
        #expect(services.cache.webKit.energySaver, "WebKit kept the full rate in Low Power Mode with the feature off")
        #expect(hibernation.neighborRadius == 0, "Low Power Mode kept neighbor tabs awake with the feature off")

        monitor.lowPowerMode.override = nil
        #expect(!services.cache.webKit.energySaver && hibernation.neighborRadius == 1)
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
