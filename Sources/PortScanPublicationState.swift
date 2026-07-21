import Foundation

/// Main-actor lifecycle gate for queue-ordered panel and agent port publications.
@MainActor
final class PortScanPublicationState {
    private var lastIssuedPanelRevision: UInt64 = 0
    private var activePanelLifecycleByKey:
        [PortScanner.PanelKey: (ttyName: String, sessionIdentity: TerminalTTYSessionIdentity?, revision: UInt64)] = [:]
    private var lastIssuedAgentRevision: UInt64 = 0
    private var activeAgentLifecycleByWorkspace:
        [UUID: (roots: Set<AgentPortRootIdentity>, revision: UInt64)] = [:]

    nonisolated init() {}

    func replacePanelLifecycle(
        key: PortScanner.PanelKey,
        ttyName: String,
        sessionIdentity: TerminalTTYSessionIdentity? = nil
    ) -> UInt64? {
        if let current = activePanelLifecycleByKey[key],
           current.ttyName == ttyName,
           current.sessionIdentity == sessionIdentity {
            return nil
        }
        lastIssuedPanelRevision &+= 1
        activePanelLifecycleByKey[key] = (ttyName, sessionIdentity, lastIssuedPanelRevision)
        return lastIssuedPanelRevision
    }

    func invalidatePanelLifecycle(for key: PortScanner.PanelKey) {
        lastIssuedPanelRevision &+= 1
        activePanelLifecycleByKey.removeValue(forKey: key)
    }

    func registeredPanelTTYName(for key: PortScanner.PanelKey) -> String? {
        activePanelLifecycleByKey[key]?.ttyName
    }

    func currentPanelTTYName(
        for key: PortScanner.PanelKey,
        sessionIdentity: TerminalTTYSessionIdentity?
    ) -> String? {
        guard let sessionIdentity,
              let current = activePanelLifecycleByKey[key],
              current.sessionIdentity == sessionIdentity else {
            return nil
        }
        return current.ttyName
    }

    func isCurrentPanelRevision(_ revision: UInt64, key: PortScanner.PanelKey) -> Bool {
        activePanelLifecycleByKey[key]?.revision == revision
    }

    func acceptCurrentPanelPublications(
        _ publications: some Sequence<PanelPortScanPublication>
    ) -> [PanelPortScanPublication] {
        publications.filter { isCurrentPanelRevision($0.revision, key: $0.key) }
    }

    func replaceAgentLifecycle(
        workspaceId: UUID,
        roots: Set<AgentPortRootIdentity>
    ) -> UInt64 {
        if let current = activeAgentLifecycleByWorkspace[workspaceId], current.roots == roots {
            return current.revision
        }
        lastIssuedAgentRevision &+= 1
        activeAgentLifecycleByWorkspace[workspaceId] = (roots, lastIssuedAgentRevision)
        return lastIssuedAgentRevision
    }

    func invalidateAgentLifecycle(for workspaceId: UUID) -> UInt64 {
        lastIssuedAgentRevision &+= 1
        activeAgentLifecycleByWorkspace.removeValue(forKey: workspaceId)
        return lastIssuedAgentRevision
    }

    func isCurrentAgentRevision(_ revision: UInt64, workspaceId: UUID) -> Bool {
        activeAgentLifecycleByWorkspace[workspaceId]?.revision == revision
    }

    func finishAgentLifecycle(workspaceId: UUID, revision: UInt64) {
        guard activeAgentLifecycleByWorkspace[workspaceId]?.revision == revision else { return }
        activeAgentLifecycleByWorkspace.removeValue(forKey: workspaceId)
    }

    func acceptCurrentAgentPublications(
        _ publications: some Sequence<AgentPortScanPublication>
    ) -> [AgentPortScanPublication] {
        publications.filter {
            activeAgentLifecycleByWorkspace[$0.workspaceId]?.revision == $0.revision
        }
    }
}
