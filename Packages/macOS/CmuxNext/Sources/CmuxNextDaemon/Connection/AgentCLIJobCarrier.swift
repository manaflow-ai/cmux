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
        throw DaemonError.missingCapabilities(["agent-cli-update-job-v1"])
    }
}
