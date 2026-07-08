import Foundation
import CmuxCore
import Darwin
import CmuxNotifications
import CmuxSidebar

extension Workspace {
    struct DetachedAgentRuntimeState {
        let panelId: UUID
        let statusEntries: [String: SidebarStatusEntry]
        let agentPIDs: [String: pid_t]
        /// Start-time identities recorded for `agentPIDs`, so a consumer can
        /// distinguish "recorded process still runs" from "pid was reused by
        /// an unrelated process" (same contract as `isRecordedAgentPIDLive`).
        let agentPIDProcessIdentities: [String: AgentPIDProcessIdentity]
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
        let directoryIsTrustedRemoteReport: Bool
        let directoryDisplayLabel: String?
        let ttyName: String?
        let cachedTitle: String?
        let customTitle: String?
        let customTitleSource: Workspace.CustomTitleSource?
        let manuallyUnread: Bool
        let restoredUnreadIndicator: RestoredPanelUnreadIndicator?
        let restorableAgent: SessionRestorableAgentSnapshot?
        let restorableAgentResumeState: RestoredAgentResumeState?
        let restoredResumeSessionWorkingDirectory: String?
        let resumeBinding: SurfaceResumeBindingSnapshot?
        /// The panel's persistent note anchor (`Workspace.noteAnchorIdsByPanelId`),
        /// carried across moves so notes attached to the live surface keep
        /// resolving in the destination workspace instead of minting a new anchor.
        let noteAnchorId: String?
        let agentRuntime: DetachedAgentRuntimeState?
        let isRemoteTerminal: Bool
        let remoteRelayPort: Int?
        let remotePTYSessionID: String?
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
                directoryIsTrustedRemoteReport: directoryIsTrustedRemoteReport,
                directoryDisplayLabel: directoryDisplayLabel,
                ttyName: ttyName,
                cachedTitle: cachedTitle,
                customTitle: customTitle,
                customTitleSource: customTitleSource,
                manuallyUnread: manuallyUnread,
                restoredUnreadIndicator: restoredUnreadIndicator,
                restorableAgent: restorableAgent,
                restorableAgentResumeState: restorableAgentResumeState,
                restoredResumeSessionWorkingDirectory: restoredResumeSessionWorkingDirectory,
                resumeBinding: resumeBinding,
                noteAnchorId: noteAnchorId,
                agentRuntime: agentRuntime,
                isRemoteTerminal: isRemoteTerminal,
                remoteRelayPort: remoteRelayPort,
                remotePTYSessionID: remotePTYSessionID,
                remoteCleanupConfiguration: configuration
            )
        }
    }
}
