import Foundation
import CmuxCore
import CmuxWorkspaces
import Darwin
import CmuxNotifications
import CmuxSidebar

extension Workspace {
    struct DetachedAgentRuntimeState {
        let panelId: UUID
        var statusEntries: [String: SidebarStatusEntry]
        var agentPIDs: [String: pid_t]
        /// Start-time identities recorded for `agentPIDs`, so a consumer can
        /// distinguish "recorded process still runs" from "pid was reused by
        /// an unrelated process" (same contract as `isRecordedAgentPIDLive`).
        var agentPIDProcessIdentities: [String: AgentPIDProcessIdentity]
        var agentPIDKeys: Set<String>
        /// Active lifecycle values follow a live panel into and out of a Dock,
        /// alongside its structured PID ownership.
        var agentLifecycleStates: [String: AgentHibernationLifecycleState] = [:]
        /// Exact lifecycle-session owner by status key while the panel is in a Dock.
        var agentLifecycleSessionIDs: [String: String] = [:]
        /// Lifecycle records established by fresh, accepted reports while the
        /// panel is Dock-owned. Entry-time Workspace records intentionally do
        /// not populate this map, so a Dock round trip cannot promote stale
        /// cached lifecycle state back into an authoritative Workspace claim.
        var authoritativeAgentLifecycleRecords: [String: AgentLifecycleRecord] = [:]
    }

    struct DetachedSurfaceTransfer {
        let sourceWorkspaceId: UUID
        /// Workspace whose restore context must rebuild this panel after relaunch.
        /// Unlike `sourceWorkspaceId`, this survives moves between Dock containers.
        let sessionRestoreSourceWorkspaceId: UUID?
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
        var ttyName: String?
        var ttyNameWasReportedByCurrentRuntime: Bool = false
        var ttyReportRuntimeSurfaceGeneration: UInt64? = nil
        let cachedTitle: String?
        let customTitle: String?
        let customTitleSource: Workspace.CustomTitleSource?
        let manuallyUnread: Bool
        let restoredUnreadIndicator: RestoredPanelUnreadIndicator?
        let restorableAgent: SessionRestorableAgentSnapshot?
        let restorableAgentResumeState: RestoredAgentResumeState?
        let restoredAgentCompletedGeneration: RestoredAgentCompletedGeneration?
        let shellActivityState: PanelShellActivityState?
        var restoredPanelTitleBoundary: RestoredPanelTitleBoundary? = nil
        let restoredResumeSessionWorkingDirectory: String?
        let resumeBinding: SurfaceResumeBindingSnapshot?
        /// Authoritative hook identity when `resumeBinding` is an effective
        /// process-detected binding.
        let managedAgentResumeBinding: SurfaceResumeBindingSnapshot?
        var agentRuntime: DetachedAgentRuntimeState?
        /// Current authoritative Dock lifecycle records, synchronized when a
        /// live Dock mutation clears or replaces its runtime owner.
        var agentLifecycleRecords: [String: AgentLifecycleRecord]
        let isRemoteTerminal: Bool
        var remoteTerminalSessionPhase: WorkspaceRemoteTerminalSessionPhase? = nil
        var remoteTerminalAuthority: WorkspaceRemoteTerminalAuthority? = nil
        var remoteTerminalLifecycleID: UUID? = nil
        var remoteTerminalAttemptID: UUID? = nil
        let remoteRelayPort: Int?
        var remoteRelayNamespaceConfiguration: WorkspaceRemoteConfiguration? = nil
        let remotePTYSessionID: String?
        let remoteCleanupConfiguration: WorkspaceRemoteConfiguration?

        var sessionRestoreWorkspaceId: UUID {
            sessionRestoreSourceWorkspaceId ?? sourceWorkspaceId
        }

        var resolvedManagedAgentResumeBinding: SurfaceResumeBindingSnapshot? {
            managedAgentResumeBinding.flatMap {
                $0.hasCompleteManagedSessionIdentity ? $0 : nil
            } ?? resumeBinding.flatMap {
                $0.hasCompleteManagedSessionIdentity ? $0 : nil
            }
        }

        func withRemoteCleanupConfiguration(_ configuration: WorkspaceRemoteConfiguration?) -> Self {
            Self(
                sourceWorkspaceId: sourceWorkspaceId,
                sessionRestoreSourceWorkspaceId: sessionRestoreSourceWorkspaceId,
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
                ttyNameWasReportedByCurrentRuntime: ttyNameWasReportedByCurrentRuntime,
                ttyReportRuntimeSurfaceGeneration: ttyReportRuntimeSurfaceGeneration,
                cachedTitle: cachedTitle,
                customTitle: customTitle,
                customTitleSource: customTitleSource,
                manuallyUnread: manuallyUnread,
                restoredUnreadIndicator: restoredUnreadIndicator,
                restorableAgent: restorableAgent,
                restorableAgentResumeState: restorableAgentResumeState,
                restoredAgentCompletedGeneration: restoredAgentCompletedGeneration,
                shellActivityState: shellActivityState,
                restoredPanelTitleBoundary: restoredPanelTitleBoundary,
                restoredResumeSessionWorkingDirectory: restoredResumeSessionWorkingDirectory,
                resumeBinding: resumeBinding,
                managedAgentResumeBinding: managedAgentResumeBinding,
                agentRuntime: agentRuntime,
                agentLifecycleRecords: agentLifecycleRecords,
                isRemoteTerminal: isRemoteTerminal,
                remoteTerminalSessionPhase: remoteTerminalSessionPhase,
                remoteTerminalAuthority: remoteTerminalAuthority,
                remoteTerminalLifecycleID: remoteTerminalLifecycleID,
                remoteTerminalAttemptID: remoteTerminalAttemptID,
                remoteRelayPort: remoteRelayPort,
                remoteRelayNamespaceConfiguration: remoteRelayNamespaceConfiguration,
                remotePTYSessionID: remotePTYSessionID,
                remoteCleanupConfiguration: configuration
            )
        }
    }
}
