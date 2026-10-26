@testable import CmuxNextEnergy
import Foundation
import IOKit.ps
import Testing

/// The power-source monitor reads off the main thread and hands the main actor a reading only when
/// the source or the low-battery band changes; a Mac without an `IOPMPowerSource` registers nothing.
@MainActor
struct BatteryLevelTests {
    /// A Mac the monitor's system calls reach. The test's thread runs the queue's work inline, so every
    /// call comes from the main thread and `MainDelivery` delivers before the call returns.
    final class FakeMac {
        var hasPowerSource = true
        var reading = PowerSourceReading()
        var reads = 0
        var handlers: [Int32: (name: String, handler: @Sendable () -> Void)] = [:]
        var registered: [String] = []
        var cancelled: [Int32] = []
        private var nextToken: Int32 = 1

        var system: PowerSourceMonitor.System {
            PowerSourceMonitor.System(hasPowerSource: { MainActor.assumeIsolated { self.hasPowerSource } },
                                      read: { MainActor.assumeIsolated { self.read() } },
                                      register: { name, handler in MainActor.assumeIsolated { self.register(name, handler) } },
                                      cancel: { token in MainActor.assumeIsolated { self.cancel(token) } },
                                      post: { work in work() })
        }

        /// The names registered now.
        var live: Set<String> { Set(handlers.values.map(\.name)) }

        private func read() -> PowerSourceReading {
            reads += 1
            return reading
        }

        private func register(_ name: String, _ handler: @escaping @Sendable () -> Void) -> Int32? {
            defer { nextToken += 1 }
            registered.append(name)
            handlers[nextToken] = (name, handler)
            return nextToken
        }

        private func cancel(_ token: Int32) {
            cancelled.append(token)
            handlers[token] = nil
        }

        /// notifyd posts `name`.
        func post(_ name: String) {
            for entry in handlers.values where entry.name == name { entry.handler() }
        }

        /// The Mac moves to `onBattery` with `percent` left, and IOKit posts what changed.
        func change(onBattery: Bool, percent: Int) {
            let sourceChanged = reading.onBattery != onBattery
            reading.onBattery = onBattery
            reading.batteryPercent = percent
            post(sourceChanged ? kIOPSNotifyPowerSource : kIOPSNotifyPercentChange)
        }
    }

    final class Deliveries {
        var readings: [PowerSourceReading] = []
    }

    static func laptop(onBattery: Bool, percent: Int) -> FakeMac {
        let mac = FakeMac()
        mac.reading = PowerSourceReading(onBattery: onBattery, hasBattery: true, batteryPercent: percent)
        return mac
    }

    static func started(_ mac: FakeMac) -> (PowerSourceMonitor, Deliveries) {
        let monitor = PowerSourceMonitor(system: mac.system)
        let deliveries = Deliveries()
        monitor.start { deliveries.readings.append($0) }
        return (monitor, deliveries)
    }

    @Test func chargeStepsAboveTheThresholdNeverReachMain() {
        let mac = Self.laptop(onBattery: true, percent: 80)
        let (monitor, deliveries) = Self.started(mac)
        #expect(deliveries.readings.count == 1, "the first reading")
        for step in 0..<30 {
            mac.change(onBattery: true, percent: 80 - step)
        }
        mac.change(onBattery: true, percent: 50)
        #expect(mac.reads == 32)
        #expect(deliveries.readings.count == 1, "80% to 50% on battery is no edge")
        _ = monitor
    }

    @Test func crossingBelowTwentyPercentReachesMainOnce() {
        let mac = Self.laptop(onBattery: true, percent: 21)
        let (monitor, deliveries) = Self.started(mac)
        mac.change(onBattery: true, percent: 20)
        #expect(deliveries.readings.count == 1)
        mac.change(onBattery: true, percent: 19)
        #expect(deliveries.readings.count == 2)
        #expect(deliveries.readings.last == PowerSourceReading(onBattery: true, hasBattery: true, batteryPercent: 19))
        mac.change(onBattery: true, percent: 19)
        #expect(deliveries.readings.count == 2, "an unchanged reading is no edge")
        _ = monitor
    }

    @Test func unpluggingReachesMainOnceAndFollowsTheChargeOnlyOnBattery() {
        let mac = Self.laptop(onBattery: false, percent: 90)
        let (monitor, deliveries) = Self.started(mac)
        #expect(mac.live == [kIOPSNotifyPowerSource], "no charge notification on AC")
        #expect(deliveries.readings.count == 1)
        mac.change(onBattery: true, percent: 90)
        #expect(deliveries.readings.count == 2)
        #expect(deliveries.readings.last?.onBattery == true)
        #expect(mac.live == [kIOPSNotifyPowerSource, kIOPSNotifyPercentChange])
        mac.change(onBattery: false, percent: 89)
        #expect(deliveries.readings.count == 3)
        #expect(mac.live == [kIOPSNotifyPowerSource], "plugged in: the charge notification ends")
        _ = monitor
    }

    @Test func aMacWithoutAPowerSourceRegistersNothing() {
        let mac = FakeMac()
        mac.hasPowerSource = false
        let monitor = EnergyMonitor(lowPowerMode: LowPowerMode(enabled: false), thermal: ThermalStateWatch(state: .nominal),
                                    power: .monitored(by: PowerSourceMonitor(system: mac.system)))
        monitor.start()
        #expect(mac.registered.isEmpty)
        #expect(mac.reads == 0)
        #expect(!monitor.inputs.hasBattery)
        #expect(!monitor.inputs.onBattery)
    }

    @Test func aPowerSourceWithoutAnInternalBatteryRegistersNothing() {
        let mac = FakeMac()
        let (monitor, deliveries) = Self.started(mac)
        #expect(mac.registered.isEmpty)
        #expect(deliveries.readings.isEmpty)
        _ = monitor
    }

    @Test func stopEndsEveryRegistrationAndStartRegistersAgain() {
        let mac = Self.laptop(onBattery: true, percent: 50)
        let (monitor, deliveries) = Self.started(mac)
        #expect(mac.live.count == 2)
        monitor.stop()
        #expect(mac.live.isEmpty)
        #expect(mac.cancelled.count == 2)
        monitor.start { deliveries.readings.append($0) }
        #expect(mac.live.count == 2)
        #expect(deliveries.readings.count == 2, "a new run sends its first reading")
    }

    @Test func aStaleNotificationAfterStopSendsNothing() {
        let mac = Self.laptop(onBattery: true, percent: 50)
        let (monitor, deliveries) = Self.started(mac)
        let stale = mac.handlers.values.map(\.handler)
        monitor.stop()
        mac.reading.batteryPercent = 10
        stale.forEach { $0() }
        #expect(deliveries.readings.count == 1)
        #expect(mac.reads == 1)
    }

    @Test func theMonitorFeedsTheEnergyInputs() {
        let mac = Self.laptop(onBattery: false, percent: 80)
        let monitor = EnergyMonitor(lowPowerMode: LowPowerMode(enabled: false), thermal: ThermalStateWatch(state: .nominal),
                                    power: .monitored(by: PowerSourceMonitor(system: mac.system)))
        monitor.start()
        #expect(monitor.inputs == EnergyInputs(hasBattery: true))
        mac.change(onBattery: true, percent: 80)
        mac.change(onBattery: true, percent: 15)
        #expect(monitor.inputs == EnergyInputs(onBattery: true, hasBattery: true, batteryPercent: 15))
    }

    @Test func theChargeIsCurrentOverFullCapacity() {
        let battery: [String: Any] = [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 1_900,
                                      kIOPSMaxCapacityKey: 10_000]
        #expect(BatteryLevel(descriptions: [battery]).percent == 19)
        #expect(BatteryLevel.percent(current: 2_000, full: 10_000) == 20)
    }
}
