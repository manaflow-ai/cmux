import Foundation
import Testing
@testable import CmuxNextDaemon

struct AgentInventoryRefreshRequestTests {
    @Test(arguments: [[], ["agent-inventory-v1", "agent-inventory-owner-v1"], ["agent-inventory-refresh-v10"]])
    func oldOwnersAreRefusedBeforeSending(capabilities: [String]) {
        do {
            try MachineAgentInventoryRefreshRequest.requireServed(by: .init(capabilities: capabilities, generation: "boot"))
            Issue.record("an owner without registry-only refresh was admitted")
        } catch DaemonError.missingCapabilities(let missing) {
            #expect(missing == ["agent-inventory-refresh-v1"])
        } catch { Issue.record("unexpected admission error: \(error)") }
    }

    @Test func requestCarriesOnlyTheOwnerCondition() throws {
        let machine: ResourceID = "machine_0123456789abcdef0123456789abcdef"
        try MachineAgentInventoryRefreshRequest.requireServed(by: .init(capabilities: ["agent-inventory-refresh-v1"], generation: "boot"))
        let encoded = try WireCoding.encodeRequest(MachineAgentInventoryRefreshRequest(expectedMachineID: machine), id: 19)
        let value = try JSONDecoder().decode(JSONValue.self, from: encoded)
        #expect(value == .object(["id": .number(19), "cmd": .string("agent-inventory-refresh"), "expected_machine_id": .string(machine.rawValue)]))
    }

    @Test func receiptKeepsExactObservationTimesAndRequiresAnInventoryOwner() throws {
        let good = #"{"machine":"machine_0123456789abcdef0123456789abcdef","view":"inventory","cached":true,"harnesses":[{"id":"profile","family":"claude","channel":"native","version":"2.0.5","latest":"2.0.9","latestCheckedAt":18446744073709551615,"outdated":true,"auth":"unknown","checkedAt":1}]}"#
        let receipt = try JSONDecoder().decode(AgentInventoryRefreshReceipt.self, from: Data(good.utf8))
        #expect(receipt.machine.rawValue == "machine_0123456789abcdef0123456789abcdef")
        #expect(receipt.inventory.harnesses.first?.latestCheckedAt == UInt64.max)
        #expect(receipt.inventory.harnesses.first?.checkedAt == 1)
        for bad in [
            good.replacingOccurrences(of: #""machine":"machine_0123456789abcdef0123456789abcdef","# , with: ""),
            good.replacingOccurrences(of: "machine_0123456789abcdef0123456789abcdef", with: "local"),
            good.replacingOccurrences(of: "inventory", with: "health"),
            good.replacingOccurrences(of: #""cached":true"#, with: #""cached":false"#),
        ] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(AgentInventoryRefreshReceipt.self, from: Data(bad.utf8))
            }
        }
    }
}
