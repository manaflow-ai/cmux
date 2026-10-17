import CmuxNextCloud
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
    }

    @Test func olderCloudMachinePayloadsUseConservativeDefaults() throws {
        let machine = try JSONDecoder().decode(CloudMachine.self, from: Data(#"{"id":"vm-old"}"#.utf8))

        #expect(!machine.capabilities.exec)
        #expect(machine.capabilities.attachTransports.isEmpty)
    }
}
