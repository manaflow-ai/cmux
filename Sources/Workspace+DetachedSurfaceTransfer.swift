import Foundation
import Bonsplit
import CmuxCore
import CmuxWorkspaces
import Darwin
import CmuxNotifications
import CmuxSidebar

extension Workspace {
    struct UndoableDetachedTerminal {
        let transfer: DetachedSurfaceTransfer
        let originalPaneId: PaneID
        let originalTabIndex: Int
        let historyEntry: ClosedPanelHistoryEntry
    }

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
        let restoredAgentCompletedGeneration: RestoredAgentCompletedGeneration?
        let shellActivityState: PanelShellActivityState?
        let restoredResumeSessionWorkingDirectory: String?
        let resumeBinding: SurfaceResumeBindingSnapshot?
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
                restoredAgentCompletedGeneration: restoredAgentCompletedGeneration,
                shellActivityState: shellActivityState,
                restoredResumeSessionWorkingDirectory: restoredResumeSessionWorkingDirectory,
                resumeBinding: resumeBinding,
                agentRuntime: agentRuntime,
                isRemoteTerminal: isRemoteTerminal,
                remoteRelayPort: remoteRelayPort,
                remotePTYSessionID: remotePTYSessionID,
                remoteCleanupConfiguration: configuration
            )
        }
    }

    func detachTerminalForUndo(panelId: UUID) -> UndoableDetachedTerminal? {
        guard panels[panelId] is TerminalPanel,
              let tabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId),
              let tabIndex = bonsplitController.tabs(inPane: paneId).firstIndex(where: { $0.id == tabId }),
              let historyEntry = closedPanelHistoryEntry(panelId: panelId, tabId: tabId, pane: paneId),
              let transfer = detachSurface(panelId: panelId) else {
            return nil
        }
        return UndoableDetachedTerminal(
            transfer: transfer,
            originalPaneId: paneId,
            originalTabIndex: tabIndex,
            historyEntry: historyEntry
        )
    }

    @discardableResult
    func restoreUndoableTerminal(_ closed: UndoableDetachedTerminal) -> Bool {
        let paneId = bonsplitController.allPaneIds.contains(closed.originalPaneId)
            ? closed.originalPaneId
            : (bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first)
        guard let paneId else { return false }
        return attachDetachedSurface(
            closed.transfer,
            inPane: paneId,
            atIndex: closed.originalTabIndex,
            focus: true
        ) != nil
    }

    func finalizeUndoableTerminal(_ closed: UndoableDetachedTerminal) {
        ClosedItemHistoryStore.shared.push(.panel(closed.historyEntry))
        AppDelegate.shared?.notificationStore?.clearNotifications(
            forTabId: closed.transfer.sourceWorkspaceId,
            surfaceId: closed.transfer.panelId
        )

        let paneId = bonsplitController.allPaneIds.contains(closed.originalPaneId)
            ? closed.originalPaneId
            : (bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first)
        if let paneId,
           attachDetachedSurface(
               closed.transfer,
               inPane: paneId,
               atIndex: closed.originalTabIndex,
               focus: false
           ) != nil {
            withClosedPanelHistorySuppressed {
                _ = closePanel(closed.transfer.panelId, force: true)
            }
            return
        }

        closed.transfer.panel.close()
    }
}
