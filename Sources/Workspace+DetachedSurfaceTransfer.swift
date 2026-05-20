import Foundation
import Darwin

extension Workspace {
    struct DetachedAgentRuntimeState {
        let panelId: UUID
        let statusEntries: [String: SidebarStatusEntry]
        let agentPIDs: [String: pid_t]
        let agentPIDKeys: Set<String>
    }

    struct DetachedSurfaceTransfer {
        let sourceWorkspaceId: UUID
        let panelId: UUID
        let panel: any Panel
        let title: String
        let icon: String?
        let iconImageData: Data?
        let kind: String?
        let isLoading: Bool
        let isPinned: Bool
        let directory: String?
        let ttyName: String?
        let cachedTitle: String?
        let customTitle: String?
        let manuallyUnread: Bool
        let restoredUnread: Bool
        let restorableAgent: SessionRestorableAgentSnapshot?
        let restorableAgentResumeState: RestoredAgentResumeState?
        let resumeBinding: SurfaceResumeBindingSnapshot?
        let agentRuntime: DetachedAgentRuntimeState?
        let isRemoteTerminal: Bool
        let remoteRelayPort: Int?
        let remoteCleanupConfiguration: WorkspaceRemoteConfiguration?

        func withRemoteCleanupConfiguration(_ configuration: WorkspaceRemoteConfiguration?) -> Self {
            Self(
                sourceWorkspaceId: sourceWorkspaceId,
                panelId: panelId,
                panel: panel,
                title: title,
                icon: icon,
                iconImageData: iconImageData,
                kind: kind,
                isLoading: isLoading,
                isPinned: isPinned,
                directory: directory,
                ttyName: ttyName,
                cachedTitle: cachedTitle,
                customTitle: customTitle,
                manuallyUnread: manuallyUnread,
                restoredUnread: restoredUnread,
                restorableAgent: restorableAgent,
                restorableAgentResumeState: restorableAgentResumeState,
                resumeBinding: resumeBinding,
                agentRuntime: agentRuntime,
                isRemoteTerminal: isRemoteTerminal,
                remoteRelayPort: remoteRelayPort,
                remoteCleanupConfiguration: configuration
            )
        }
    }
}
