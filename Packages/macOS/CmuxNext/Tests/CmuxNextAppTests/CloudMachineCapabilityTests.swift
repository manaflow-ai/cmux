@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

@Suite
struct CloudMachineCapabilityTests {
    @Test func cloudMachineKeepsProviderCapabilities() throws {
        let data = Data(#"{"id":"vm-1","provider":"freestyle","status":"running","capabilities":{"exec":true,"ports":true,"attachTransports":["cmux-remote"]}}"#.utf8)
        let machine = try JSONDecoder().decode(CloudMachine.self, from: data)

        #expect(machine.capabilities.exec)
        #expect(machine.capabilities.ports)
        #expect(machine.capabilities.attachTransports == ["cmux-remote"])
        #expect(!machine.capabilities.desktop)
        #expect(machine.capabilities.supports(.exec))
        #expect(machine.capabilities.supportedOperations == [.exec, .ports])
    }

    @Test func olderCloudMachinePayloadsUseConservativeDefaults() throws {
        let machine = try JSONDecoder().decode(CloudMachine.self, from: Data(#"{"id":"vm-old"}"#.utf8))

        #expect(!machine.capabilities.exec)
        #expect(machine.capabilities.attachTransports.isEmpty)
        #expect(machine.capabilities.supportedOperations.isEmpty)
    }

    @Test func absentCapabilitiesAllowEveryAction() throws {
        let machine = try JSONDecoder().decode(CloudMachine.self, from: Data(#"{"id":"vm-old"}"#.utf8))

        #expect(machine.declaredCapabilities == nil)
        for operation in CloudMachine.Capabilities.Operation.allCases {
            #expect(machine.allows(operation), "\(operation)")
        }
        #expect(CloudMachine(id: "vm-local").allows(.snapshot))
    }

    @Test func explicitlyFalseCapabilitiesRefuseTheirActions() throws {
        let data = Data(#"{"id":"vm-1","capabilities":{"snapshot":false,"fork":false,"ports":true}}"#.utf8)
        let machine = try JSONDecoder().decode(CloudMachine.self, from: data)

        #expect(!machine.allows(.snapshot))
        #expect(!machine.allows(.fork))
        #expect(!machine.allows(.sizing))
        #expect(machine.allows(.ports))
    }

    @Test func capabilityNameListDecodes() throws {
        let data = Data(#"{"id":"vm-2","capabilities":["exec","persistent_home","agent_session"]}"#.utf8)
        let machine = try JSONDecoder().decode(CloudMachine.self, from: data)

        #expect(machine.declaredCapabilities != nil)
        #expect(machine.capabilities.supportedOperations == [.exec, .persistentHome])
        #expect(machine.allows(.exec))
        #expect(!machine.allows(.snapshot))
    }

    /// A Worker machine offers what the app reaches for it (app server ops, the Worker's exec and
    /// file routes) and refuses what would only go to `/api/vm`, where it has no record.
    @Test func cmuxNextBackendRecordsOfferOnlyWorkerActions() throws {
        let record = JSONValue.object([
            "id": .string("m-1"), "status": .string("running"), "capabilities": .array([.string("agent_session")]),
        ])
        let machine = try #require(CloudMachine(next: record))

        for operation in [CloudMachine.Capabilities.Operation.snapshot, .restore, .exec, .sizing] { #expect(machine.allows(operation)) }
        for operation in [CloudMachine.Capabilities.Operation.fork, .ports, .stats, .desktop, .restart] { #expect(!machine.allows(operation)) }
    }

    @Test func cmuxNextBackendIdlePolicyReadsAsIdlePauseMinutes() throws {
        let record = JSONValue.object([
            "id": .string("m-2"), "status": .string("running"), "idle_policy": .object(["idle_seconds": .number(1800)]),
        ])
        #expect(try #require(CloudMachine(next: record)).idlePauseMinutes == 30)
    }
}
