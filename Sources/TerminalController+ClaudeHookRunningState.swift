import Foundation

@MainActor
extension TerminalController {
    /// Part of the existing exact live-owner read, not a telemetry mutation.
    /// The main actor is necessary to snapshot the same state the sidebar shows.
    func claudeHookCanSkipRunning(
        ownerID: UUID,
        surfaceID: UUID,
        workspace: Workspace?,
        dock: DockSplitStore?
    ) -> Bool {
        let key = "claude_code"
        let status: String?
        let anotherPanelNeedsInput: Bool
        if let dock {
            guard let runtime = dock.agentRuntimeByPanelId[surfaceID],
                  runtime.agentLifecycleStates[key] == .running else { return false }
            status = runtime.statusEntries[key]?.value
            anotherPanelNeedsInput = false
        } else if let workspace {
            guard workspace.hasRunningAgentLifecycle(key: key, panelId: surfaceID) else { return false }
            status = workspace.statusEntries[key]?.value
            // Workspace status is shared by same-provider panes. Another pane's
            // legitimate attention must not cause writes on every tool here.
            anotherPanelNeedsInput = workspace.agentLifecycleStatesByPanelId.contains {
                $0.key != surfaceID && $0.value[key] == .needsInput
            }
        } else {
            return false
        }
        // A sibling's typed needs-input state owns the shared status. Its
        // display text can be localized (or come from a differently localized
        // CLI), so it cannot decide whether this running pane needs a mutation.
        guard status == "Running" || anotherPanelNeedsInput else {
            return false
        }
        let notifications = TerminalNotificationStore.shared
        return !notifications.hasUnreadNotification(forTabId: ownerID, surfaceId: surfaceID)
            && !notifications.hasPendingNotification(forTabId: ownerID, surfaceId: surfaceID)
    }
}
