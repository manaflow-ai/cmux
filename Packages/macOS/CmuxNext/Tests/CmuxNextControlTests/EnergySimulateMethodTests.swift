#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// `debug.energy.simulate`: each input by its wire name reaches the monitor's
/// simulation in one main-actor turn before the answer, which is `debug.energy`'s report;
/// `{clear: true}` alone hands it nil; anything else is `invalid_params` and changes nothing.
@Suite(.timeLimit(.minutes(1)))
struct EnergySimulateMethodTests {
    /// What the app's monitor was handed, in order.
    @MainActor final class Monitor {
        var applied: [EnergySimulation?] = []
    }

    /// The services' state while the monitor holds a simulation (`simulated`) or not.
    private static func state(simulated: Bool) -> EnergyReport.State {
        EnergyReport.State(
            policy: simulated ? EnergyPolicy(saverReason: .battery, onBattery: true) : .normal,
            inputs: EnergyReport.Inputs(featureEnabled: true, lowPowerMode: false, onBattery: simulated, hasBattery: simulated,
                                        batteryPercent: simulated ? 15 : nil, thermal: .nominal, setting: .auto,
                                        sessionOverride: false, simulated: simulated),
            wakeQueue: .init(entries: 0, coalescedFires: 0),
            cef: .init(saver: .unsupported, earlyPasses: nil)
        )
    }

    @MainActor
    private static func report(_ monitor: Monitor) -> EnergyReport {
        EnergyReport(state: { state(simulated: (monitor.applied.last ?? nil) != nil) }, ledger: WakeupLedger(), processes: { [] })
    }

    @MainActor
    private static func router(_ monitor: Monitor) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        router.register([report(monitor).simulateMethod { monitor.applied.append($0) }])
        return router
    }

    /// A mutation: the main-actor lane, through the work queue, in the automation class behind the person's input.
    @MainActor
    @Test func itIsAnAutomationMutation() {
        let method = Self.report(Monitor()).simulateMethod { _ in }
        #expect(method.lane == .mainActor)
        #expect(method.workClass == .automation)
    }

    /// The answer is the state the applying turn made: simulated after a simulation, not after a clear.
    @MainActor
    @Test func theBenchsBatteryParamsReachTheMonitorAndAnswerTheReport() async throws {
        let monitor = Monitor()
        let router = Self.router(monitor)
        let reply = try await router.handle(ControlRequest(method: EnergyReport.simulateMethodName,
                                                           params: ["on_battery": .bool(true), "percent": .number(15)])).get()
        #expect(monitor.applied == [EnergySimulation(onBattery: true, batteryPercent: 15)])
        #expect(reply["policy"]?["reason"]?.stringValue == "battery")
        #expect(reply["inputs"]?["simulated"] == JSONValue.bool(true))
        let cleared = try await router.handle(ControlRequest(method: EnergyReport.simulateMethodName, params: ["clear": .bool(true)])).get()
        #expect(monitor.applied == [EnergySimulation(onBattery: true, batteryPercent: 15), nil])
        #expect(cleared["inputs"]?["simulated"] == JSONValue.bool(false))
        #expect(cleared["policy"]?["isSaver"] == JSONValue.bool(false))
    }

    @MainActor
    @Test func refusedParamsChangeNothing() async {
        let monitor = Monitor()
        let router = Self.router(monitor)
        let result = await router.handle(ControlRequest(method: EnergyReport.simulateMethodName, params: ["percent": .number(140)]))
        #expect(throws: ControlError.self) { try result.get() }
        #expect(monitor.applied.isEmpty)
    }

    @Test func everyInputHasItsWireName() throws {
        let simulation = try EnergyReport.simulation([
            "on_battery": .bool(false), "percent": .number(0), "thermal": .string("serious"),
            "low_power": .bool(true), "suspended": .bool(true),
        ])
        #expect(simulation == EnergySimulation(onBattery: false, batteryPercent: 0, thermal: .serious, lowPowerMode: true, suspended: true))
        #expect(try EnergyReport.simulation(["clear": .bool(true)]) == nil)
    }

    @Test(arguments: [
        [:],
        ["clear": JSONValue.bool(false)],
        ["clear": .bool(true), "percent": .number(15)],
        ["percent": .number(101)],
        ["percent": .number(14.5)],
        ["percent": .string("15")],
        ["thermal": .string("hot")],
        ["on_battery": .string("yes")],
        ["battery": .bool(true)],
    ] as [[String: JSONValue]])
    func otherParamsAreInvalid(_ params: [String: JSONValue]) {
        let error = #expect(throws: ControlError.self) { try EnergyReport.simulation(params) }
        #expect(error?.code == "invalid_params")
    }
}
#endif
