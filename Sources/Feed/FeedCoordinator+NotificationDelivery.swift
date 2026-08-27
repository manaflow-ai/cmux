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
        guard let appDelegate = AppDelegate.shared else {
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
        guard let target = liveNotificationTarget(for: event, resolved: resolved) else {
            // A surface claim that no longer exists must never fall back to a
            // stale workspace (or to the focused panel). Drop the external
            // effects until a producer supplies a live target.
            return .resolve(
                isAppFocused: appFocused,
                isActiveTab: false,
                isFocusedSurface: false,
                isMuted: true,
                effects: effects
            )
        }
        let ownerID = target.ownerID
        let surfaceID = target.surfaceID

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

    /// Resolves the live owner used for Feed notification admission. A surface
    /// claim is only a validated hint: the current surface registry wins after
    /// a pane move, while workspace-only events may use the hook-session match.
    @MainActor
    private func liveNotificationTarget(
        for event: WorkstreamEvent,
        resolved: (ownerId: UUID, surfaceId: UUID?)?
    ) -> (ownerID: UUID, surfaceID: UUID?)? {
        let claimedWorkspaceID: UUID?
        if let rawWorkspaceID = event.workspaceId {
            let normalizedWorkspaceID = rawWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedWorkspaceID.isEmpty {
                claimedWorkspaceID = nil
            } else {
                guard let workspaceID = UUID(uuidString: normalizedWorkspaceID) else {
                    return nil
                }
                claimedWorkspaceID = workspaceID
            }
        } else {
            claimedWorkspaceID = nil
        }
        if let rawSurfaceID = event.surfaceId {
            let normalizedSurfaceID = rawSurfaceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedSurfaceID.isEmpty else {
                // Empty wire values have historically represented an omitted
                // surface; malformed non-empty values fail closed below.
                return targetForWorkspaceOnlyEvent(
                    claimedWorkspaceID: claimedWorkspaceID,
                    resolved: resolved
                )
            }
            guard let claimedSurfaceID = UUID(uuidString: normalizedSurfaceID) else {
                return nil
            }
            guard let live = AppDelegate.shared?.liveSurfaceOwner(
                surfaceID: claimedSurfaceID,
                preferredTabID: claimedWorkspaceID
            ) else {
                return nil
            }
            return (ownerID: live.tabID, surfaceID: live.surfaceID)
        }

        return targetForWorkspaceOnlyEvent(
            claimedWorkspaceID: claimedWorkspaceID,
            resolved: resolved
        )
    }

    private func targetForWorkspaceOnlyEvent(
        claimedWorkspaceID: UUID?,
        resolved: (ownerId: UUID, surfaceId: UUID?)?
    ) -> (ownerID: UUID, surfaceID: UUID?)? {
        if let resolved,
           let resolvedSurfaceID = resolved.surfaceId {
            guard let live = AppDelegate.shared?.liveSurfaceOwner(
                surfaceID: resolvedSurfaceID,
                preferredTabID: resolved.ownerId
            ) else {
                return nil
            }
            return (ownerID: live.tabID, surfaceID: live.surfaceID)
        }
        if let claimedWorkspaceID {
            guard AppDelegate.shared?.agentNotificationDeliveryTarget(
                claimedTabId: claimedWorkspaceID,
                surfaceId: nil
            ) != nil else {
                return nil
            }
            return (ownerID: claimedWorkspaceID, surfaceID: resolved?.surfaceId)
        }
        guard let resolved else { return nil }
        return (ownerID: resolved.ownerId, surfaceID: resolved.surfaceId)
    }
}
