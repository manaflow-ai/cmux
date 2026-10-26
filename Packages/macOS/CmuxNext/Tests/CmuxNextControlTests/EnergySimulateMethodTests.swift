#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// `debug.energy.simulate` (p14-energy-123): each input by its wire name reaches the monitor's
/// simulation in one main-actor turn before the answer, which is `debug.energy`'s report;
/// `{clear: true}` alone hands it nil; anything else is `invalid_params` and changes nothing.
@Suite(.timeLimit(.minutes(1)))
struct EnergySimulateMethodTests {
    /// What the app's monitor was handed, in order.
    @MainActor final class Monitor {
        var applied: [EnergySimulation?] = []
    }

    private static let state = EnergyReport.State(
        policy: EnergyPolicy(saverReason: .battery, onBattery: true),
        inputs: EnergyReport.Inputs(featureEnabled: true, lowPowerMode: false, onBattery: true, hasBattery: true, batteryPercent: 15,
                                    thermal: .nominal, setting: .auto, sessionOverride: false, simulated: true),
        wakeQueue: .init(entries: 0, coalescedFires: 0),
        cef: .init(saver: .unsupported, earlyPasses: nil)
    )

    @MainActor
    private static func router(_ monitor: Monitor) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        let report = EnergyReport(state: { state }, ledger: WakeupLedger(), processes: { [] })
        router.register([report.simulateMethod { monitor.applied.append($0) }])
        return router
    }

    @MainActor
    @Test func theBenchsBatteryParamsReachTheMonitorAndAnswerTheReport() async throws {
        let monitor = Monitor()
        let router = Self.router(monitor)
        let reply = try await router.handle(ControlRequest(method: EnergyReport.simulateMethodName,
                                                           params: ["on_battery": .bool(true), "percent": .number(15)])).get()
        #expect(monitor.applied == [EnergySimulation(onBattery: true, batteryPercent: 15)])
        #expect(reply["policy"]?["reason"]?.stringValue == "battery")
        #expect(reply["inputs"]?["simulated"] == JSONValue.bool(true))
        _ = try await router.handle(ControlRequest(method: EnergyReport.simulateMethodName, params: ["clear": .bool(true)])).get()
        #expect(monitor.applied == [EnergySimulation(onBattery: true, batteryPercent: 15), nil])
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
