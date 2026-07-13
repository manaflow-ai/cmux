import Foundation

/// Main-actor lifecycle gate for queued agent port publications.
@MainActor
final class PortScanPublicationState {
    private var lastIssuedAgentRevision: UInt64 = 0
    private var activeAgentRevisionByWorkspace: [UUID: UInt64] = [:]

    nonisolated init() {}

    func nextAgentRevision(for workspaceId: UUID) -> UInt64 {
        lastIssuedAgentRevision &+= 1
        activeAgentRevisionByWorkspace[workspaceId] = lastIssuedAgentRevision
        return lastIssuedAgentRevision
    }

    func isCurrentAgentRevision(_ revision: UInt64, workspaceId: UUID) -> Bool {
        activeAgentRevisionByWorkspace[workspaceId] == revision
    }

    func finishAgentLifecycle(workspaceId: UUID, revision: UInt64) {
        guard activeAgentRevisionByWorkspace[workspaceId] == revision else { return }
        activeAgentRevisionByWorkspace.removeValue(forKey: workspaceId)
    }
}
