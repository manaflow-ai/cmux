@testable import CmuxNextEnergy
import Foundation
import IOKit.ps
import Testing

/// The energy monitor holds Low Power Mode, the power source, the battery's charge and the thermal
/// state as one value, registers no power-source notification on a Mac without a battery, reads
/// the power source once per change (one IOKit snapshot) and reports the charge only on battery.
@MainActor
struct EnergyMonitorTests {
    /// A power source a test drives: what it reads, and the change handler the monitor registered.
    @MainActor final class FakePower {
        var reading = PowerSourceReading()
        var listens = 0
        var reads = 0
        var stops = 0
        var changed: (@MainActor () -> Void)?

        var input: PowerSourceInput {
            PowerSourceInput(read: {
                self.reads += 1
                return self.reading
            }, listen: { handler in
                self.listens += 1
                self.changed = handler
            }, stop: {
                self.stops += 1
                self.changed = nil
            })
        }

        /// The Mac moves to `onBattery` with `percent` left, and IOKit says so.
        func change(onBattery: Bool, percent: Int?) {
            reading.onBattery = onBattery
            reading.batteryPercent = percent
            changed?()
        }
    }

    final class Seen {
        var inputs: [EnergyInputs] = []
    }

    /// The Low Power Mode values an observer heard.
    final class Heard {
        var values: [Bool] = []
    }

    static func laptop(percent: Int?, onBattery: Bool = false) -> PowerSourceReading {
        PowerSourceReading(onBattery: onBattery, hasBattery: true, batteryPercent: percent)
    }

    static func monitor(_ power: FakePower, lowPowerMode: LowPowerMode = LowPowerMode(enabled: false),
                        thermal: ThermalStateWatch = ThermalStateWatch(state: .nominal)) -> EnergyMonitor {
        EnergyMonitor(lowPowerMode: lowPowerMode, thermal: thermal, power: power.input)
    }

    @Test func aMacWithoutABatteryRegistersNothing() {
        let power = FakePower()
        let monitor = Self.monitor(power)
        monitor.start()
        #expect(power.listens == 0)
        #expect(power.reads == 1)
        #expect(monitor.inputs == EnergyInputs())
        #expect(!monitor.inputs.hasBattery)
    }

    @Test func nothingReadsThePowerSourceBeforeStart() {
        let power = FakePower()
        power.reading = Self.laptop(percent: 50, onBattery: true)
        let monitor = Self.monitor(power)
        #expect(power.reads == 0 && power.listens == 0)
        #expect(!monitor.inputs.onBattery)
    }

    /// Start used to make two or three IOKit calls (the battery, the source, the battery again on
    /// battery); each change two. One snapshot answers both now.
    @Test func startAndEachChangeReadThePowerSourceOnce() {
        let power = FakePower()
        power.reading = Self.laptop(percent: 70, onBattery: true)
        let monitor = Self.monitor(power)
        monitor.start()
        #expect(power.reads == 1)
        #expect(monitor.inputs == EnergyInputs(onBattery: true, hasBattery: true, batteryPercent: 70))
        power.change(onBattery: true, percent: 69)
        #expect(power.reads == 2)
    }

    @Test func stopEndsTheNotificationAndStartListensAgain() {
        let power = FakePower()
        power.reading = Self.laptop(percent: 70)
        let monitor = Self.monitor(power)
        monitor.stop()
        #expect(power.stops == 0, "a monitor never started has nothing to stop")
        monitor.start()
        monitor.stop()
        #expect(power.stops == 1 && power.changed == nil)
        monitor.start()
        #expect(power.listens == 2)
    }

    @Test func aLaptopReportsItsSourceAndChargeOnBatteryOnly() {
        let power = FakePower()
        power.reading = Self.laptop(percent: 80)
        let monitor = Self.monitor(power)
        let seen = Seen()
        let registration = monitor.observe { seen.inputs.append($0) }
        monitor.start()
        monitor.start()
        #expect(power.listens == 1)
        #expect(monitor.inputs == EnergyInputs(hasBattery: true))
        power.change(onBattery: true, percent: 55)
        #expect(monitor.inputs == EnergyInputs(onBattery: true, hasBattery: true, batteryPercent: 55))
        power.change(onBattery: false, percent: 54)
        #expect(monitor.inputs == EnergyInputs(hasBattery: true), "the charge was reported on AC")
        #expect(seen.inputs == [EnergyInputs(hasBattery: true), EnergyInputs(onBattery: true, hasBattery: true, batteryPercent: 55),
                                EnergyInputs(hasBattery: true)])
        _ = registration
    }

    @Test func anUnchangedReadingTellsNobody() {
        let power = FakePower()
        power.reading = Self.laptop(percent: 40, onBattery: true)
        let monitor = Self.monitor(power)
        monitor.start()
        let seen = Seen()
        let registration = monitor.observe { seen.inputs.append($0) }
        power.change(onBattery: true, percent: 40)
        #expect(seen.inputs.isEmpty)
        _ = registration
    }

    @Test func lowPowerModeAndThermalStateReachTheInputs() {
        let lowPowerMode = LowPowerMode(enabled: false)
        let thermal = ThermalStateWatch(state: .nominal)
        let monitor = Self.monitor(FakePower(), lowPowerMode: lowPowerMode, thermal: thermal)
        let seen = Seen()
        let registration = monitor.observe { seen.inputs.append($0) }
        lowPowerMode.override = true
        #expect(monitor.inputs.lowPowerMode)
        thermal.override = .serious
        #expect(monitor.inputs.thermal == .serious)
        thermal.override = nil
        lowPowerMode.override = nil
        #expect(monitor.inputs == EnergyInputs())
        #expect(seen.inputs.count == 4)
        _ = registration
    }

    @Test func followTellsTheInputsNowThenEachChange() {
        let lowPowerMode = LowPowerMode(enabled: true)
        let monitor = Self.monitor(FakePower(), lowPowerMode: lowPowerMode)
        let seen = Seen()
        let registration = monitor.follow { seen.inputs.append($0) }
        #expect(seen.inputs == [EnergyInputs(lowPowerMode: true)])
        lowPowerMode.override = false
        #expect(seen.inputs == [EnergyInputs(lowPowerMode: true), EnergyInputs()])
        _ = registration
    }

    @Test func aCancelledRegistrationHearsNothing() {
        let lowPowerMode = LowPowerMode(enabled: false)
        let monitor = Self.monitor(FakePower(), lowPowerMode: lowPowerMode)
        let seen = Seen()
        let registration = monitor.observe { seen.inputs.append($0) }
        registration.cancel()
        lowPowerMode.override = true
        #expect(seen.inputs.isEmpty)
    }

    @Test func theThermalWatchFollowsItsCenter() {
        let center = NotificationCenter()
        var state = ProcessInfo.ThermalState.nominal
        let watch = ThermalStateWatch(center: center) { state }
        var heard: [ProcessInfo.ThermalState] = []
        watch.onChange = { heard.append($0) }
        state = .critical
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        #expect(watch.state == .critical)
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        #expect(heard == [.critical])
    }

    /// Low Power Mode follows its center through one main-queue observer, in the
    /// post's own turn on main (no task hop), tells its observers once per change, and stops when released.
    @Test func lowPowerModeFollowsItsCenterInThePostsTurn() {
        let center = NotificationCenter()
        var enabled = false
        var mode: LowPowerMode? = LowPowerMode(center: center) { enabled }
        let heard = Heard()
        let observation = mode?.observe { heard.values.append($0) }
        enabled = true
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        #expect(mode?.isEnabled == true, "the post's own turn applied the change")
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        #expect(heard.values == [true], "an unchanged value told the observers again")
        mode = nil
        enabled = false
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        #expect(heard.values == [true], "a released mode still heard its center")
        _ = observation
    }

    @Test func theBatteryIsTheInternalOneAndItsChargeIsCurrentOverFull() {
        let ups: [String: Any] = [kIOPSTypeKey: kIOPSUPSType, kIOPSCurrentCapacityKey: 90, kIOPSMaxCapacityKey: 100]
        let internalBattery: [String: Any] = [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 3_100, kIOPSMaxCapacityKey: 4_000]
        #expect(BatteryLevel(descriptions: []) == BatteryLevel())
        #expect(!BatteryLevel(descriptions: [ups]).hasBattery)
        let battery = BatteryLevel(descriptions: [ups, internalBattery])
        #expect(battery.hasBattery && battery.percent == 78)
        #expect(BatteryLevel.percent(current: 19, full: 100) == 19)
        #expect(BatteryLevel.percent(current: 120, full: 100) == 100)
        #expect(BatteryLevel.percent(current: 10, full: 0) == nil)
        #expect(BatteryLevel.percent(current: nil, full: 100) == nil)
    }
}
