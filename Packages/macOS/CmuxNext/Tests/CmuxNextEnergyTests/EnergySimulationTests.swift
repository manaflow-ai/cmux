@testable import CmuxNextEnergy
import CmuxNextWakeups
import Foundation
import Testing

/// `debug.energy.simulate` (p14-energy-123): a simulation lays inputs over the Mac's in the monitor, the
/// driver resolves the policy from them in the same turn, and clearing it restores the Mac's inputs. Fleet
/// Macs have no battery, so 15% on battery is how the bench sees the `auto` saver's `battery` reason.
@MainActor
struct EnergySimulationTests {
    /// A Mac with no battery: IOKit reads nothing and registers nothing.
    static func desktop() -> EnergyMonitor {
        EnergyMonitor(lowPowerMode: LowPowerMode(enabled: false), thermal: ThermalStateWatch(state: .nominal),
                      power: PowerSourceInput(read: { PowerSourceReading() }, listen: { _ in }))
    }

    /// The monitor feeding a driver in `setting`, as AppServices wires them.
    @MainActor final class Wired {
        let monitor: EnergyMonitor
        let source: EnergyPolicySource
        /// The monitor's registration of the driver, held for the test's length.
        let registration: AnyObject

        init(setting: EnergySaverMode) {
            let monitor = EnergySimulationTests.desktop()
            let source = EnergyPolicySource()
            let driver = EnergyPolicyDriver(source: source, isEnabled: true)
            driver.update(setting: setting)
            registration = monitor.follow { driver.update(inputs: $0) }
            monitor.start()
            self.monitor = monitor
            self.source = source
        }
    }

    @Test func fifteenPercentOnBatteryTurnsTheAutoSaverOnForTheBattery() {
        let wired = Wired(setting: .auto)
        #expect(wired.source.policy == .normal)
        wired.monitor.simulate(EnergySimulation(onBattery: true, batteryPercent: 15))
        #expect(wired.monitor.inputs == EnergyInputs(onBattery: true, hasBattery: true, batteryPercent: 15))
        #expect(wired.source.policy == EnergyPolicy(saverReason: .battery, onBattery: true))
        #expect(wired.source.policy.wakeAlignment == WakeLeeway.saverAlignment)
    }

    @Test func twentyPercentOnBatteryLeavesTheAutoSaverOff() {
        let wired = Wired(setting: .auto)
        wired.monitor.simulate(EnergySimulation(onBattery: true, batteryPercent: 20))
        #expect(wired.source.policy == EnergyPolicy(onBattery: true))
    }

    @Test func clearingRestoresTheMacsInputsAndPolicy() {
        let wired = Wired(setting: .auto)
        wired.monitor.simulate(EnergySimulation(onBattery: true, batteryPercent: 15, thermal: .critical, lowPowerMode: true, suspended: true))
        #expect(wired.monitor.simulation != nil && wired.monitor.isSimulated)
        wired.monitor.simulate(nil)
        #expect(wired.monitor.simulation == nil && !wired.monitor.isSimulated)
        #expect(wired.monitor.inputs == EnergyInputs())
        #expect(wired.source.policy == .normal)
    }

    @Test func aNewSimulationReplacesTheLastOne() {
        let wired = Wired(setting: .auto)
        wired.monitor.simulate(EnergySimulation(onBattery: true, batteryPercent: 15))
        wired.monitor.simulate(EnergySimulation(lowPowerMode: true))
        #expect(wired.monitor.inputs == EnergyInputs(lowPowerMode: true))
        #expect(wired.source.policy == EnergyPolicy(saverReason: .lowPowerMode))
    }

    @Test func thermalOnBatteryAndSuspendReachThePolicy() {
        let wired = Wired(setting: .auto)
        wired.monitor.simulate(EnergySimulation(thermal: .critical))
        #expect(wired.source.policy == .normal, "thermal never turns the saver on while plugged in")
        wired.monitor.simulate(EnergySimulation(onBattery: true, batteryPercent: 80, thermal: .serious, suspended: true))
        #expect(wired.source.policy == EnergyPolicy(saverReason: .thermal, suspended: true, onBattery: true))
    }

    /// Inputs not simulated follow the Mac: its Low Power Mode and thermal changes still arrive.
    @Test func inputsNotSimulatedFollowTheMac() {
        let lowPowerMode = LowPowerMode(enabled: false)
        let thermal = ThermalStateWatch(state: .nominal)
        let monitor = EnergyMonitor(lowPowerMode: lowPowerMode, thermal: thermal,
                                    power: PowerSourceInput(read: { PowerSourceReading() }, listen: { _ in }))
        monitor.simulate(EnergySimulation(onBattery: true))
        thermal.override = .fair
        lowPowerMode.override = true
        #expect(monitor.inputs == EnergyInputs(lowPowerMode: true, onBattery: true, hasBattery: true, thermal: .fair))
        monitor.simulate(EnergySimulation(lowPowerMode: false))
        #expect(monitor.inputs == EnergyInputs(thermal: .fair), "the simulation, not the Mac, holds Low Power Mode off")
    }

    /// A charge is reported only on battery, simulated or not; on AC it is dropped, as the Mac's is.
    @Test func aChargeOffBatteryIsNotReported() {
        let monitor = Self.desktop()
        monitor.simulate(EnergySimulation(batteryPercent: 15))
        #expect(monitor.inputs == EnergyInputs(hasBattery: true))
        #expect(EnergySimulation(batteryPercent: 140).batteryPercent == 100)
        #expect(EnergySimulation(batteryPercent: -3).batteryPercent == 0)
    }
}
