import Foundation

/// Immutable inputs for one agent-owned process-tree port scan.
struct AgentPortScanRequest: Sendable, Equatable {
    let workspaceIds: Set<UUID>
    let rootInput: AgentPortScanRootInput
    let agentRevisions: [UUID: UInt64]
    let requestID: UInt64

    func merging(_ newer: Self) -> Self {
        var revisions = agentRevisions
        for workspaceId in newer.workspaceIds {
            revisions[workspaceId] = newer.agentRevisions[workspaceId]
        }
        return Self(
            workspaceIds: workspaceIds.union(newer.workspaceIds),
            rootInput: rootInput.merging(newer.rootInput, workspaceIds: newer.workspaceIds),
            agentRevisions: revisions,
            requestID: newer.requestID
        )
    }
}
