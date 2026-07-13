import Foundation

/// Immutable inputs for one agent-owned process-tree port scan.
struct AgentPortScanRequest: Sendable, Equatable {
    let workspaceIds: Set<UUID>
    let pidInput: AgentPortScanPIDInput
    let agentRevisions: [UUID: UInt64]
    let requestID: UInt64

    func merging(_ newer: Self) -> Self {
        var revisions = agentRevisions
        for workspaceId in newer.workspaceIds {
            revisions[workspaceId] = newer.agentRevisions[workspaceId]
        }
        return Self(
            workspaceIds: workspaceIds.union(newer.workspaceIds),
            pidInput: pidInput.merging(newer.pidInput),
            agentRevisions: revisions,
            requestID: newer.requestID
        )
    }

    func resolvingPIDs(
        _ pidsByWorkspace: [UUID: Set<Int>],
        currentRevisions: [UUID: UInt64]
    ) -> (request: Self, inactiveWorkspaceIds: Set<UUID>) {
        let validWorkspaceIds = Set(workspaceIds.filter {
            currentRevisions[$0, default: 0] == agentRevisions[$0, default: 0]
        })
        let normalizedPIDs = pidsByWorkspace.reduce(into: [UUID: Set<Int>]()) { partial, item in
            guard validWorkspaceIds.contains(item.key) else { return }
            let validPIDs = Set(item.value.filter { $0 > 0 })
            guard !validPIDs.isEmpty else { return }
            partial[item.key] = validPIDs
        }
        let request = Self(
            workspaceIds: validWorkspaceIds,
            pidInput: .captured(normalizedPIDs),
            agentRevisions: agentRevisions.filter { validWorkspaceIds.contains($0.key) },
            requestID: requestID
        )
        return (request, validWorkspaceIds.subtracting(normalizedPIDs.keys))
    }
}
