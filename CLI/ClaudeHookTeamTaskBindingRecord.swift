import CMUXAgentLaunch
import Foundation

/// One durable automatic-team proof retained across independent hook processes.
struct ClaudeHookTeamTaskBindingRecord: Codable, Equatable {
    /// Hard cap for cross-workspace reconciliation fan-out.
    static let maximumWorkspaceCount = 64
    /// Hard cap for durable automatic-team cleanup proofs.
    static let maximumRecordCount = 128

    /// The exact leader/member identities that own the shared task list.
    let binding: ClaudeTeamTaskListBinding
    /// Exact workspaces that have received this shared checklist owner.
    let workspaceIDs: [String]
    /// The last time a live team config or matching cleanup hook confirmed it.
    let updatedAt: TimeInterval

    private enum CodingKeys: String, CodingKey {
        case binding
        case workspaceIDs
        case updatedAt
    }

    init(
        binding: ClaudeTeamTaskListBinding,
        workspaceIDs: [String],
        updatedAt: TimeInterval
    ) {
        self.binding = binding
        self.workspaceIDs = workspaceIDs
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        binding = try container.decode(ClaudeTeamTaskListBinding.self, forKey: .binding)
        workspaceIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .workspaceIDs
        ) ?? []
        updatedAt = try container.decode(TimeInterval.self, forKey: .updatedAt)
    }
}
