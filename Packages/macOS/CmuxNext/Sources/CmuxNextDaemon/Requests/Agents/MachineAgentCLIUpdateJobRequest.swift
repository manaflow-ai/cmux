import Foundation

/// Requests a fixed update job on exactly one machine and daemon session.
/// The caller retains the original key through lost replies and reattachment.
/// The job opens a workspace whose terminal runs the update, so it spawns.
public nonisolated struct MachineAgentCLIUpdateJobRequest: TerminalSpawningRequest {
    public typealias Response = AgentCLIJobReceipt
    public static let commandName: DaemonCommandName = "agent-cli-update-job"
    public static let requiredCapability: String? = "agent-cli-update-job-v1"
    /// The exact canonical machine admitted by the caller's route.
    public let expectedMachineID: ResourceID
    /// The exact canonical session on that machine, never a routing selector.
    public let expectedSessionID: ResourceID
    /// An evidenced CLI family; the owner selects its installation and updater.
    public let cli: String
    /// The original intent key, reused when a creation reply is lost.
    public let idempotencyKey: String

    /// Creates an intent without generating keys, resolving targets or selecting argv.
    public init(expectedMachineID: ResourceID, expectedSessionID: ResourceID,
                cli: AgentCLIFamily, idempotencyKey: String) {
        self.expectedMachineID = expectedMachineID
        self.expectedSessionID = expectedSessionID
        self.cli = cli.rawValue
        self.idempotencyKey = idempotencyKey
    }

    enum CodingKeys: String, CodingKey {
        case expectedMachineID = "expected_machine_id", expectedSessionID = "expected_session_id", cli
        case idempotencyKey = "idempotency_key"
    }
}
