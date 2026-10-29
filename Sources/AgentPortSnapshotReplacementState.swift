import CmuxCore
import Foundation

/// Queue-confined bound for retaining a snapshot across an agent-root transition.
struct AgentPortSnapshotReplacementState {
    private let incompleteRetentionLimit: Int
    private var incompleteScanCountsByWorkspace: [UUID: Int] = [:]

    init(incompleteRetentionLimit: Int = 2) {
        self.incompleteRetentionLimit = max(0, incompleteRetentionLimit)
    }

    mutating func begin(workspaceId: UUID) {
        incompleteScanCountsByWorkspace[workspaceId] = 0
    }

    mutating func cancel(workspaceId: UUID) {
        incompleteScanCountsByWorkspace.removeValue(forKey: workspaceId)
    }

    mutating func workspacesToReplace(
        from scannedWorkspaceIds: Set<UUID>,
        completeness: PortScanCompleteness
    ) -> Set<UUID> {
        var replacements: Set<UUID> = []
        for workspaceId in scannedWorkspaceIds where incompleteScanCountsByWorkspace[workspaceId] != nil {
            let shouldReplace: Bool
            switch completeness {
            case .complete:
                shouldReplace = true
            case .incomplete:
                let nextCount = incompleteScanCountsByWorkspace[workspaceId, default: 0] + 1
                incompleteScanCountsByWorkspace[workspaceId] = nextCount
                shouldReplace = nextCount > incompleteRetentionLimit
            }
            if shouldReplace {
                replacements.insert(workspaceId)
                incompleteScanCountsByWorkspace.removeValue(forKey: workspaceId)
            }
        }
        return replacements
    }
}
