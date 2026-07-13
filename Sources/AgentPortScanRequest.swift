import Foundation

/// Immutable inputs for one agent-owned process-tree port scan.
struct AgentPortScanRequest: Sendable, Equatable {
    let workspaceIds: Set<UUID>
    let agentPIDsByWorkspace: [UUID: Set<Int>]
    let agentRevisions: [UUID: UInt64]
    let requestID: UInt64

    func merging(_ newer: Self) -> Self {
        var pids = agentPIDsByWorkspace
        var revisions = agentRevisions
        for workspaceId in newer.workspaceIds {
            pids[workspaceId] = newer.agentPIDsByWorkspace[workspaceId]
            revisions[workspaceId] = newer.agentRevisions[workspaceId]
        }
        return Self(
            workspaceIds: workspaceIds.union(newer.workspaceIds),
            agentPIDsByWorkspace: pids,
            agentRevisions: revisions,
            requestID: newer.requestID
        )
    }
}
