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

    @Test func cmuxNextBackendRecordsKeepCloudActions() throws {
        let record = JSONValue.object([
            "id": .string("m-1"), "status": .string("running"), "capabilities": .array([.string("agent_session")]),
        ])
        let machine = try #require(CloudMachine(next: record))

        #expect(machine.allows(.ports))
        #expect(machine.allows(.fork))
    }
}
