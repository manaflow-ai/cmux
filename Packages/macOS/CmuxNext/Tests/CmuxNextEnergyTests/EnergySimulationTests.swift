#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextEnergy
import CmuxNextWakeups
import Foundation
import Testing

/// `debug.energy.simulate`: a simulation lays inputs over the Mac's in the monitor, the
/// driver resolves the policy from them in the same turn, and clearing it restores the Mac's inputs. Fleet
/// Macs have no battery, so 15% on battery is how the bench sees the `auto` saver's `battery` reason.
/// Low Power Mode and the thermal state go through the Mac's own seams, so every reader sees them; a
/// simulated power source never ends "Turn Off Energy Saver for Now".
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

    /// The inputs each change handed the monitor's observers.
    @MainActor final class Seen {
        var inputs: [EnergyInputs] = []
        var lowPowerMode: [Bool] = []
    }

    @Test func fifteenPercentOnBatteryTurnsTheAutoSaverOnForTheBattery() {
        let wired = Wired(setting: .auto)
        #expect(wired.source.policy == .normal)
        wired.monitor.simulate(EnergySimulation(onBattery: true, batteryPercent: 15))
        #expect(wired.monitor.inputs == EnergyInputs(onBattery: true, macOnBattery: false, hasBattery: true, batteryPercent: 15))
        #expect(wired.source.policy == EnergyPolicy(saverReason: .battery, onBattery: true))
        #expect(wired.source.policy.wakeAlignment == WakeLeeway.saverAlignment)
    }

    @Test func twentyPercentOnBatteryLeavesTheAutoSaverOff() {
        let wired = Wired(setting: .auto)
        wired.monitor.simulate(EnergySimulation(onBattery: true, batteryPercent: 20))
        #expect(wired.source.policy == EnergyPolicy(onBattery: true))
    }

    @Test func clearingRestoresTheMacsInputsPolicyAndSeams() {
        let wired = Wired(setting: .auto)
        wired.monitor.simulate(EnergySimulation(onBattery: true, batteryPercent: 15, thermal: .critical, lowPowerMode: true, suspended: true))
        #expect(wired.monitor.simulation != nil && wired.monitor.isSimulated)
        wired.monitor.simulate(nil)
        #expect(wired.monitor.simulation == nil && !wired.monitor.isSimulated)
        #expect(wired.monitor.inputs == EnergyInputs())
        #expect(wired.source.policy == .normal)
        #expect(wired.monitor.lowPowerMode.override == nil)
        #expect(wired.monitor.thermal.override == nil)
    }

    @Test func aNewSimulationReplacesTheLastOne() {
        let wired = Wired(setting: .auto)
        wired.monitor.simulate(EnergySimulation(onBattery: true, batteryPercent: 15, thermal: .serious))
        wired.monitor.simulate(EnergySimulation(lowPowerMode: true))
        #expect(wired.monitor.inputs == EnergyInputs(lowPowerMode: true))
        #expect(wired.monitor.thermal.override == nil, "the thermal state the last simulation set goes back")
        #expect(wired.source.policy == EnergyPolicy(saverReason: .lowPowerMode))
    }

    @Test func thermalOnBatteryAndSuspendReachThePolicy() {
        let wired = Wired(setting: .auto)
        wired.monitor.simulate(EnergySimulation(thermal: .critical))
        #expect(wired.source.policy == .normal, "thermal never turns the saver on while plugged in")
        wired.monitor.simulate(EnergySimulation(onBattery: true, batteryPercent: 80, thermal: .serious, suspended: true))
        #expect(wired.source.policy == EnergyPolicy(saverReason: .thermal, suspended: true, onBattery: true))
    }

    /// Low Power Mode and the thermal state go through the Mac's seams, so the hibernation and the glass
    /// watch (which read `lowPowerMode`) see the same Mac as the policy; the monitor's observers hear one change.
    @Test func simulatedLowPowerAndThermalReachTheSeams() {
        let monitor = Self.desktop()
        let seen = Seen()
        let inputs = monitor.observe { seen.inputs.append($0) }
        let lowPowerMode = monitor.lowPowerMode.observe { seen.lowPowerMode.append($0) }
        monitor.simulate(EnergySimulation(onBattery: true, batteryPercent: 15, thermal: .serious, lowPowerMode: true))
        #expect(monitor.lowPowerMode.isEnabled)
        #expect(monitor.thermal.state == .serious)
        #expect(seen.lowPowerMode == [true])
        #expect(seen.inputs == [EnergyInputs(lowPowerMode: true, onBattery: true, macOnBattery: false, hasBattery: true,
                                             batteryPercent: 15, thermal: .serious)])
        monitor.simulate(nil)
        #expect(!monitor.lowPowerMode.isEnabled)
        #expect(monitor.thermal.state == .nominal)
        #expect(seen.lowPowerMode == [true, false])
        #expect(seen.inputs.count == 2)
        withExtendedLifetime((inputs, lowPowerMode)) {}
    }

    /// Inputs not simulated follow the Mac: its Low Power Mode and thermal changes still arrive, and
    /// clearing puts back the overrides `debug.low_power_mode` and the thermal watch held.
    @Test func inputsNotSimulatedFollowTheMac() {
        let lowPowerMode = LowPowerMode(enabled: false)
        let thermal = ThermalStateWatch(state: .nominal)
        let monitor = EnergyMonitor(lowPowerMode: lowPowerMode, thermal: thermal,
                                    power: PowerSourceInput(read: { PowerSourceReading() }, listen: { _ in }))
        monitor.simulate(EnergySimulation(onBattery: true))
        thermal.override = .fair
        lowPowerMode.override = true
        #expect(monitor.inputs == EnergyInputs(lowPowerMode: true, onBattery: true, macOnBattery: false, hasBattery: true, thermal: .fair))
        monitor.simulate(EnergySimulation(lowPowerMode: false))
        #expect(monitor.inputs == EnergyInputs(thermal: .fair), "the simulation, not the Mac, holds Low Power Mode off")
        monitor.simulate(nil)
        #expect(lowPowerMode.override == true, "debug.low_power_mode's override comes back")
        #expect(thermal.override == .fair, "a seam no simulation took is left alone")
        #expect(monitor.inputs == EnergyInputs(lowPowerMode: true, thermal: .fair))
    }

    /// A charge is reported only on battery, simulated or not; on AC it is dropped, as the Mac's is.
    @Test func aChargeOffBatteryIsNotReported() {
        let monitor = Self.desktop()
        monitor.simulate(EnergySimulation(batteryPercent: 15))
        #expect(monitor.inputs == EnergyInputs(hasBattery: true))
        #expect(EnergySimulation(batteryPercent: 140).batteryPercent == 100)
        #expect(EnergySimulation(batteryPercent: -3).batteryPercent == 0)
    }

    /// On an AC Mac, simulating battery power and clearing it is no plug-in: "Turn Off for Now" holds.
    @Test func simulatingBatteryAndClearingKeepsTurnOffForNow() {
        let monitor = Self.desktop()
        var resolver = EnergyPolicyResolver(isEnabled: true)
        _ = resolver.update(setting: .auto, inputs: monitor.inputs)
        resolver.turnOffForNow()
        monitor.simulate(EnergySimulation(onBattery: true, batteryPercent: 15))
        #expect(resolver.update(setting: .auto, inputs: monitor.inputs) == nil)
        monitor.simulate(nil)
        #expect(resolver.update(setting: .auto, inputs: monitor.inputs) == nil)
        #expect(resolver.isOffForSession)
    }

    /// On a laptop really on battery, a simulated AC is no plug-in either; the Mac's own plug-in still
    /// ends "Turn Off for Now" while a simulation holds the power source.
    @Test func onlyTheMacsOwnPlugInEndsTurnOffForNow() {
        let power = EnergyMonitorTests.FakePower()
        power.reading = EnergyMonitorTests.laptop(percent: 50, onBattery: true)
        let monitor = EnergyMonitorTests.monitor(power)
        monitor.start()
        var resolver = EnergyPolicyResolver(isEnabled: true)
        _ = resolver.update(setting: .auto, inputs: monitor.inputs)
        resolver.turnOffForNow()
        monitor.simulate(EnergySimulation(onBattery: false))
        _ = resolver.update(setting: .auto, inputs: monitor.inputs)
        monitor.simulate(nil)
        _ = resolver.update(setting: .auto, inputs: monitor.inputs)
        #expect(resolver.isOffForSession, "a simulated AC is no plug-in")
        monitor.simulate(EnergySimulation(onBattery: true, batteryPercent: 15))
        power.change(onBattery: false, percent: 50)
        #expect(monitor.inputs.onBattery && !monitor.inputs.macOnBattery)
        _ = resolver.update(setting: .auto, inputs: monitor.inputs)
        #expect(!resolver.isOffForSession, "the Mac was plugged in")
    }
}
#endif
