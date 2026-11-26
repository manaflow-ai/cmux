import Foundation

/// Captured process roots for one or more agent-owned port scans.
struct AgentPortScanRootInput: Sendable, Equatable {
    let rootsByWorkspace: [UUID: Set<AgentPortRootIdentity>]

    func merging(_ newer: Self, workspaceIds: Set<UUID>) -> Self {
        var merged = rootsByWorkspace
        for workspaceId in workspaceIds {
            if let roots = newer.rootsByWorkspace[workspaceId], !roots.isEmpty {
                merged[workspaceId] = roots
            } else {
                merged.removeValue(forKey: workspaceId)
            }
        }
        return Self(rootsByWorkspace: merged)
    }
}
