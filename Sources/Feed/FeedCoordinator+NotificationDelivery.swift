import CMUXAgentLaunch
import Foundation

extension FeedCoordinator {
    /// Applies the same focus and workspace-mute admission policy used by the
    /// regular terminal notification store to Feed's direct UserNotifications
    /// lane. Feed events can target either a workspace or a window-owned Dock,
    /// so resolve the owner from the wire id first and consult the session map
    /// only when the event omitted it.
    @MainActor
    func feedNotificationDeliveryDecision(
        for event: WorkstreamEvent,
        effects: TerminalNotificationPolicyEffects
    ) async -> TerminalNotificationDeliveryDecision {
        // Use the shared focus resolver so Feed and terminal notifications
        // observe the same application-focus policy. Tests and debug tooling
        // configure that resolver through ``AppFocusState`` itself rather than
        // coupling this production lane to Feed-only test hooks.
        let appFocused = AppFocusState.isAppFocused()

        let resolved = await resolveAttentionTarget(event: event)
        let ownerID = event.workspaceId.flatMap {
            UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        } ?? resolved?.ownerId
        let surfaceID = event.surfaceId.flatMap {
            UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        } ?? resolved?.surfaceId

        guard let ownerID, let appDelegate = AppDelegate.shared else {
            // Preserve the historical app-wide suppression when Feed cannot
            // resolve a concrete workspace or Dock target.
            return .resolve(
                isAppFocused: appFocused,
                isActiveTab: appFocused,
                isFocusedSurface: appFocused,
                isMuted: false,
                effects: effects
            )
        }

        if let dock = appDelegate.existingWindowDock(forWindowId: ownerID) {
            let context = appDelegate.mainWindowContexts.values.first {
                $0.windowId == ownerID
            }
            let isKeyWindow = context?.window?.isKeyWindow == true
            let isFocusedSurface = surfaceID == nil || dock.focusedPanelId == surfaceID
            return .resolve(
                isAppFocused: appFocused,
                isActiveTab: isKeyWindow,
                isFocusedSurface: isFocusedSurface,
                isMuted: false,
                effects: effects
            )
        }

        let context = appDelegate.contextContainingTabId(ownerID)
        let manager = context?.tabManager
            ?? appDelegate.tabManagerFor(tabId: ownerID)
            ?? appDelegate.tabManager
        let isActiveTab = manager?.selectedTabId == ownerID
        let isFocusedSurface = surfaceID == nil
            || manager?.focusedSurfaceId(for: ownerID) == surfaceID
        let isMuted = TerminalNotificationStore.shared
            .isWorkspaceNotificationsMuted(forTabId: ownerID)

        return .resolve(
            isAppFocused: appFocused,
            isActiveTab: isActiveTab,
            isFocusedSurface: isFocusedSurface,
            isMuted: isMuted,
            effects: effects
        )
    }
}
