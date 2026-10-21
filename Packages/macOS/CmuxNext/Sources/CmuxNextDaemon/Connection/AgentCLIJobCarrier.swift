import Foundation

/// A proved machine/session control transport captured for native UI job intent.
/// It never reconnects, starts an owner, chooses commands or admits an app principal.
public nonisolated struct AgentCLIJobCarrier: Sendable {
    /// The canonical machine of the captured control transport.
    public let machine: ResourceID
    /// The canonical session of that transport, preserved across this carrier's lifetime.
    public let session: ResourceID
    let transport: LineTransport
    let identity: DaemonIdentity

    /// Resolves the original key without preparing or starting an update.
    public func resolveUpdate(cli: AgentCLIFamily, idempotencyKey: String) async throws -> AgentCLIJobResolution {
        try Resolve.requireServed(by: identity)
        guard cli != .unknown, !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, idempotencyKey.utf8.count <= 128,
              !idempotencyKey.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw DaemonError.malformedResponse("A known CLI and original intent key are required")
        }
        let result = try await DaemonRequestExecutor(transport: transport).perform(
            Resolve(expectedMachineID: machine, expectedSessionID: session, cli: cli.rawValue, idempotencyKey: idempotencyKey),
            timeout: .seconds(10))
        if case .created(let receipt) = result {
            guard receipt.machine == machine, receipt.session == session, receipt.cli == cli else {
                throw DaemonError.malformedResponse("Resolved receipt did not match the original owner and CLI")
            }
        }
        return result
    }

    private struct Resolve: DaemonRequest {
        typealias Response = AgentCLIJobResolution
        static let command = "agent-cli-update-job-resolve"
        static let requiredCapability: String? = "agent-cli-update-job-resolve-v1"
        let expectedMachineID: ResourceID
        let expectedSessionID: ResourceID
        let cli: String
        let idempotencyKey: String
    }

    /// Reads family evidence on this captured transport before an explicit update.
    public func inventory() async throws -> AcpmuxHarnessInventory {
        try MachineAgentInventoryRequest.requireServed(by: identity)
        return try await DaemonRequestExecutor(transport: transport).perform(
            MachineAgentInventoryRequest(expectedMachineID: machine), timeout: .seconds(15))
    }

    /// Starts or replays one explicit intent using its original key.
    /// A lost reply does not establish refusal; retain the same intent for recovery.
    public func startUpdate(cli: AgentCLIFamily, idempotencyKey: String) async throws -> AgentCLIJobReceipt {
        try Task.checkCancellation()
        guard cli != .unknown, !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              idempotencyKey.utf8.count <= 128,
              !idempotencyKey.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw DaemonError.command(cmd: MachineAgentCLIUpdateJobRequest.command,
                message: "A known CLI and original intent key are required", code: "agent_cli_job.bad_request")
        }
        let request = MachineAgentCLIUpdateJobRequest(expectedMachineID: machine, expectedSessionID: session,
                                                       cli: cli, idempotencyKey: idempotencyKey)
        // The native owner bounds preparation at five seconds, then starts
        // the host. This transport remains captured through the whole call.
        let receipt = try await DaemonRequestExecutor(transport: transport).perform(request, timeout: .seconds(15))
        guard receipt.machine == machine, receipt.session == session, receipt.cli == cli else {
            throw DaemonError.malformedResponse("Job receipt did not match the captured owner, session and CLI")
        }
        return receipt
    }

    /// Observes the original terminal on this same transport with a bounded wait.
    /// Cancelling observation never ends the owner's process or creates a new intent.
    public func observe(_ job: AgentCLIJobReceipt) async throws -> AgentCLIJobStatus {
        try Task.checkCancellation()
        guard job.machine == machine, job.session == session else {
            throw DaemonError.malformedResponse("Job receipt did not match the captured owner and session")
        }
        let params: [String: JSONValue] = [
            "machine": .string(machine.rawValue),
            "session": .string(session.rawValue),
            "terminal": .string(job.path.terminalID.rawValue),
            "timeout_ms": .string("5000"),
        ]
        let response = try await transport.request(cmd: "terminal.wait_exit", timeout: .seconds(8)) { id in
            try ResourceRequestEnvelope(id: id, operation: "terminal.wait_exit", params: params).line()
        }
        let status = try ResourceRequestEnvelope.decodeResult(AgentCLIJobStatus.self, from: response.line)
        guard status.terminalID == job.path.terminalID else {
            throw DaemonError.malformedResponse("Job status did not match the original terminal")
        }
        return status
    }
}
