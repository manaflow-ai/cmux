import Foundation

/// Workspace-scoped notification mute state.
///
/// The workspace owns the persisted bit, while the notification store owns
/// the single mutation seam used by both sidebar implementations and every
/// notification producer. Keeping the gate here prevents a context menu from
/// accidentally muting only one delivery path.
@MainActor
extension TerminalNotificationStore {
    /// Returns whether the workspace currently suppresses notification
    /// delivery. Missing workspaces are treated as unmuted so a stale menu
    /// action cannot hide notifications for a newly-created workspace.
    func isWorkspaceNotificationsMuted(forTabId tabId: UUID) -> Bool {
        let workspace = AppDelegate.shared?.workspaceFor(tabId: tabId)
            ?? AppDelegate.shared?.tabManager?.tabs.first(where: { $0.id == tabId })
        return workspace?.isMuted == true
    }

    /// Returns whether every workspace in a selection is muted. An empty
    /// selection is never considered muted.
    func allWorkspaceNotificationsMuted(forTabIds tabIds: [UUID]) -> Bool {
        !tabIds.isEmpty && tabIds.allSatisfy { isWorkspaceNotificationsMuted(forTabId: $0) }
    }

    /// Applies one workspace-mute mutation to a selection and reports whether
    /// at least one persisted workspace value changed.
    @discardableResult
    func setWorkspaceNotificationsMuted(_ muted: Bool, forTabIds tabIds: [UUID]) -> Bool {
        let uniqueIds = Set(tabIds)
        guard !uniqueIds.isEmpty else { return false }
        var changed = false
        for tabId in uniqueIds {
            let workspace = AppDelegate.shared?.workspaceFor(tabId: tabId)
                ?? AppDelegate.shared?.tabManager?.tabs.first(where: { $0.id == tabId })
            guard let workspace, workspace.isMuted != muted else { continue }
            workspace.isMuted = muted
            changed = true
        }
        return changed
    }

    @discardableResult
    func muteNotifications(forTabIds tabIds: [UUID]) -> Bool {
        setWorkspaceNotificationsMuted(true, forTabIds: tabIds)
    }

    @discardableResult
    func unmuteNotifications(forTabIds tabIds: [UUID]) -> Bool {
        setWorkspaceNotificationsMuted(false, forTabIds: tabIds)
    }

#if DEBUG
    /// Clears workspace mutes for isolated behavior tests.
    func clearNotificationMutesForTesting() {
        for workspace in AppDelegate.shared?.tabManager?.tabs ?? [] {
            workspace.isMuted = false
        }
    }
#endif
}
