/// A completed admission distinguishes an accepted receipt from a proven absent lease.
enum AgentInventoryWatchAdmission: Sendable {
    case accepted(AgentInventoryWatchReceipt)
    case refused(DaemonError)

    static func perform(transport: LineTransport, machine: ResourceID, supportsReceipts: Bool) async throws -> Self {
        let receipt: AgentInventoryWatchReceipt
        if supportsReceipts {
            do {
                receipt = try await DaemonConnection.perform(MachineAgentInventoryAdmissionRequest(expectedMachineID: machine),
                                                             on: transport, timeout: .seconds(15))
            } catch let error as DaemonError {
                if case .command("agent-inventory-watch", _, let code, let details, _) = error,
                   let code, ["agent_inventory.busy", "agent_inventory.unavailable", "agent_inventory.unsupported"].contains(code),
                   details?["machine"]?.stringValue == machine.rawValue,
                   details?["admission"]?.stringValue == "not_admitted" {
                    return .refused(error)
                }
                throw error
            }
        } else {
            receipt = try await DaemonConnection.perform(MachineAgentInventoryWatchRequest(expectedMachineID: machine),
                                                         on: transport, timeout: .seconds(15))
        }
        guard receipt.machine == machine else { throw DaemonError.malformedResponse("Inventory watch receipt owner mismatch") }
        return .accepted(receipt)
    }
}
