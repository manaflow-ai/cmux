import Foundation
import Testing
@testable import CmuxNextDaemon

struct MachineAgentInventoryRequestTests {
    @Test(arguments: [[], ["agent-inventory-v1"], ["agent-inventory-owner-v10"]])
    func unfencedOwnersAreRefusedBeforeEncoding(capabilities: [String]) {
        let identity = DaemonIdentity(capabilities: capabilities, generation: "boot")
        do {
            try MachineAgentInventoryRequest.requireServed(by: identity)
            Issue.record("an owner without identity fencing was admitted")
        } catch DaemonError.missingCapabilities(let missing) {
            #expect(missing == ["agent-inventory-owner-v1"])
        } catch {
            Issue.record("unexpected admission failure: \(error)")
        }
    }

    @Test func selectedOwnerIsEncodedAsAFenceWithoutRoutingOrControlParams() throws {
        let identity = DaemonIdentity(capabilities: ["agent-inventory-owner-v1"], generation: "boot")
        try MachineAgentInventoryRequest.requireServed(by: identity)
        let selected: ResourceID = "machine_0123456789abcdef0123456789abcdef"
        let request = MachineAgentInventoryRequest(expectedMachineID: selected)
        let data = try WireCoding.encodeRequest(request, id: 19)
        let fields = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(fields == .object([
            "cmd": .string("agent-inventory"), "id": .number(19),
            "expected_machine_id": .string(selected.rawValue),
        ]))
    }
}
