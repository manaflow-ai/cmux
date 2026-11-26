import Foundation

/// Workspace-scoped notification mute state.
///
/// The workspace owns the persisted bit, while the notification store owns
/// the single mutation seam used by both sidebar implementations and every
/// notification producer. Keeping the gate here prevents a context menu from
/// accidentally muting only one delivery path.
@MainActor
extension TerminalNotificationStore {
    private func workspace(for tabId: UUID) -> Workspace? {
        guard let appDelegate = AppDelegate.shared else { return nil }
        if let workspace = appDelegate.workspaceFor(tabId: tabId) {
            return workspace
        }
        // `workspaceFor` already consults the registered tab-manager index;
        // retain only the legacy active-manager fallback for early startup.
        return appDelegate.tabManager?.tabs.first(where: { $0.id == tabId })
    }

    /// Returns whether the workspace currently suppresses notification
    /// delivery. Missing workspaces are treated as unmuted so a stale menu
    /// action cannot hide notifications for a newly-created workspace.
    func isWorkspaceNotificationsMuted(forTabId tabId: UUID) -> Bool {
        workspace(for: tabId)?.isMuted == true
    }

    /// Resolves the workspace used for the first notification-mute admission
    /// check. Surface-scoped local notifications follow a moved surface, so
    /// the check must use its current owner before policy hooks run.
    func notificationMuteAdmissionTabID(
        claimedTabId: UUID,
        surfaceId: UUID?,
        retargetsToLiveSurfaceOwner: Bool
    ) -> UUID {
        guard retargetsToLiveSurfaceOwner,
              let surfaceId,
              let liveTarget = AppDelegate.shared?.agentNotificationDeliveryTarget(
                  claimedTabId: claimedTabId,
                  surfaceId: surfaceId
              ) else {
            return claimedTabId
        }
        return liveTarget.tabId
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
            let workspace = workspace(for: tabId)
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

}
