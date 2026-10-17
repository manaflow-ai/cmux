import Foundation
import Testing
@testable import CmuxNextDaemon

struct AgentInventoryWatchRequestTests {
    private let machine: ResourceID = "machine_0123456789abcdef0123456789abcdef"
    private let watch = "inventory_watch_0123456789abcdef0123456789abcdef"

    @Test(arguments: [[], ["agent-inventory-v1"], ["agent-inventory-owner-v1"], ["agent-inventory-watch-v1"], ["agent-inventory-watch-fence-v10"]])
    func bothDirectionsRefuseOwnersWithoutTheExactWatchCapability(capabilities: [String]) {
        let identity = DaemonIdentity(capabilities: capabilities, generation: "boot")
        expectRefused(MachineAgentInventoryWatchRequest.self, identity: identity)
        expectRefused(MachineAgentInventoryUnwatchRequest.self, identity: identity)
    }

    private func expectRefused<R: DaemonRequest>(_ type: R.Type, identity: DaemonIdentity) {
        do {
            try R.requireServed(by: identity)
            Issue.record("an owner without watch support was admitted")
        } catch DaemonError.missingCapabilities(let missing) {
            #expect(missing == ["agent-inventory-watch-fence-v1"])
        } catch { Issue.record("unexpected refusal: \(error)") }
    }

    @Test func enablingAndDisablingEncodeOnlyTheCapturedOwnerAndFixedBoolean() throws {
        let identity = DaemonIdentity(capabilities: ["agent-inventory-watch-fence-v1"], generation: "boot")
        try MachineAgentInventoryWatchRequest.requireServed(by: identity)
        try MachineAgentInventoryUnwatchRequest.requireServed(by: identity)
        let enable = try WireCoding.encodeRequest(MachineAgentInventoryWatchRequest(expectedMachineID: machine), id: 1)
        let disable = try WireCoding.encodeRequest(MachineAgentInventoryUnwatchRequest(expectedMachineID: machine, expectedWatchID: watch), id: 2)
        for (data, id, enabled) in [(enable, 1, true), (disable, 2, false)] {
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            var expected: [String: JSONValue] = ["cmd": .string("agent-inventory-watch"), "id": .number(Double(id)),
                                                 "expected_machine_id": .string(machine.rawValue), "enabled": .bool(enabled)]
            if !enabled { expected["expected_watch_id"] = .string(watch) }
            #expect(value == .object(expected))
        }
    }

    @Test(arguments: [UInt64(0), 9_007_199_254_740_993, UInt64.max])
    func enablingReceiptsDecodeExactUnsignedRevisions(revision: UInt64) throws {
        let line = #"{"ok":true,"data":{"machine":"\#(machine.rawValue)","watch_id":"\#(watch)","revision":\#(revision)}}"#
        let receipt = try WireCoding.decodeResponse(AgentInventoryWatchReceipt.self, from: Data(line.utf8))
        #expect(receipt.machine == machine)
        #expect(receipt.watchID == watch)
        #expect(receipt.revision == revision)
    }

    @Test func normalizedNoticesExposeTypedValuesAndStripDiagnostics() throws {
        let change = #"{"event":"agent-inventory-changed","machine":"\#(machine.rawValue)","watch_id":"\#(watch)","revision":18446744073709551615,"diagnostics":"private"}"#
        let changed = DaemonEvent.decode(name: "agent-inventory-changed", line: Data(change.utf8))
        guard case .changed(let receipt) = try #require(AgentInventoryWatchEvent(changed)) else {
            Issue.record("typed inventory change"); return
        }
        #expect(receipt.machine == machine)
        #expect(receipt.watchID == watch)
        #expect(receipt.revision == UInt64.max)
        let end = #"{"event":"agent-inventory-watch-ended","machine":"\#(machine.rawValue)","watch_id":"\#(watch)","reason":"agent_inventory.unavailable","diagnostics":"private"}"#
        let ended = DaemonEvent.decode(name: "agent-inventory-watch-ended", line: Data(end.utf8))
        #expect(AgentInventoryWatchEvent(ended) == .ended(machine: machine, watchID: watch, reason: "agent_inventory.unavailable"))
        guard case .unknown(_, let payload) = ended else { Issue.record("side event"); return }
        #expect(payload["diagnostics"] == nil)
        #expect(AgentInventoryWatchEvent(.unknown(name: "unrelated-test-event", payload: payload)) == nil)
    }

    @Test(arguments: ["private@example.test", "agent_inventory.private token", "agent_inventory.", String(repeating: "x", count: 80)])
    func malformedEndReasonsNeverReachTheConsumer(reason: String) throws {
        let fields: JSONValue = .object(["event": .string("agent-inventory-watch-ended"),
                                        "machine": .string(machine.rawValue), "watch_id": .string(watch), "reason": .string(reason)])
        let event = DaemonEvent.decode(name: "agent-inventory-watch-ended", line: try JSONEncoder().encode(fields))
        #expect(AgentInventoryWatchEvent(event) == nil)
        guard case .unknown(_, let payload) = event else { Issue.record("side event"); return }
        #expect(payload == .null)
    }
}
