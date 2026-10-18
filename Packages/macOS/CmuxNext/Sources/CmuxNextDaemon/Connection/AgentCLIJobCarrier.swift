import Foundation

/// A proved machine/session control transport captured for native UI job intent.
/// It never reconnects, starts an owner, chooses commands or admits an app principal.
public nonisolated struct AgentCLIJobCarrier: Sendable {
    /// The canonical machine of the captured control transport.
    public let machine: ResourceID
    /// The canonical session of that transport, preserved across this carrier's lifetime.
    public let session: ResourceID
    let transport: LineTransport

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
}
