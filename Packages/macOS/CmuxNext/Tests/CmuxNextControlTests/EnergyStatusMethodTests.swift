import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// `energy.status`: served in every build (no `#if DEBUG` here), it answers exactly the policy and
/// the inputs `debug.energy` reports under the same keys, which `cmux energy status` and the MCP `energy_status` tool read.
@Suite(.timeLimit(.minutes(1)))
struct EnergyStatusMethodTests {
    @MainActor
    @Test func itAnswersThePolicyAndItsInputsOnly() async throws {
        let inputs = EnergyReport.Inputs(featureEnabled: true, lowPowerMode: false, onBattery: true, hasBattery: true,
                                         batteryPercent: 15, thermal: .nominal, setting: .auto, sessionOverride: false)
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        router.register([EnergyReport.statusMethod { (policy: EnergyPolicy(saverReason: .battery, onBattery: true), inputs: inputs) }])
        let reply = try await router.handle(ControlRequest(method: "energy.status", params: [:])).get()
        let object = try #require(reply.objectValue)
        #expect(Set(object.keys) == ["policy", "inputs"])
        #expect(reply["policy"]?["isSaver"] == JSONValue.bool(true))
        #expect(reply["policy"]?["reason"]?.stringValue == "battery")
        #expect(reply["inputs"]?["batteryPercent"]?.intValue == 15)
        #expect(reply["inputs"]?["sessionOverride"] == JSONValue.bool(false))
        #expect(EnergyReport.statusMethodName == "energy.status")
    }

    @MainActor
    @Test func itAnswersNullOnceTheServicesAreGone() async throws {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        router.register([EnergyReport.statusMethod { nil }])
        let reply = try await router.handle(ControlRequest(method: EnergyReport.statusMethodName, params: [:])).get()
        #expect(reply == JSONValue.null)
    }
}
