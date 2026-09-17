import CMUXAgentLaunch
import CmuxAgentJournal
import CmuxFoundation
import CmuxSettings
import Foundation

extension FeedCoordinator {
    /// The accepted Feed decision fans out through the existing store for history,
    /// unread, pane flash, reorder, and push. Feed retains its actionable native
    /// banner renderer; both lanes consume the same policy effects exactly once.
    @MainActor
    func acceptSemanticFeedNotification(
        event: WorkstreamEvent, requestId: String, title: String, subtitle: String,
        body: String, effects: TerminalNotificationPolicyEffects,
        soundContext: NotificationSoundOverrideContext?
    ) async -> Bool {
        let settings = NotificationsCatalogSection()
        guard settings.agentPermissionPrompt.value(in: .standard) else { return false }
        guard let resolved = await resolveAttentionTarget(event: event),
              let surfaceID = resolved.surfaceId,
              let target = AppDelegate.shared?.agentNotificationDeliveryTarget(
                claimedTabId: resolved.ownerId, surfaceId: surfaceID),
              let liveSurfaceID = target.surfaceId else { return false }
        let input = AgentFeedSemanticInput(event: event,
            agentKey: Self.lifecycleStatusKey(forSource: event.source),
            notification: AgentJournalNotification(title: title, subtitle: subtitle,
                body: body, category: "needs-permission", correlationKey: requestId),
            requestID: requestId, workspaceID: target.tabId, surfaceID: liveSurfaceID)
        guard await notificationJournal.admitFeedNotification(input),
              isAwaitingDecision(requestId: requestId) else { return false }
        var storeEffects = effects
        // The actionable banner below owns these three effects. Disabling them
        // here prevents a second banner/sound/command from the history lane.
        storeEffects.desktop = false
        storeEffects.sound = false
        storeEffects.command = false
        let request = TerminalNotificationPolicyRequest(tabId: target.tabId,
            surfaceId: liveSurfaceID, retargetsToLiveSurfaceOwner: true,
            correlationKey: requestId, title: title, subtitle: subtitle, body: body,
            cwd: event.cwd, isAppFocused: AppFocusState.isAppFocused(), isFocusedPanel: false,
            agent: TerminalNotificationPolicyAgentContext(kind: event.source,
                category: "needs-permission", pending: false, isSubagent: false, sessionId: input.sessionID), soundContext: soundContext)
        guard AgentJournalLifecycleCenter.notificationRequestIsCurrent(request) else { return false }
        _ = TerminalNotificationStore.shared.applyNotification(request: request, effects: storeEffects,
            now: Date(), cooldownReservation: nil, scrollPosition: nil, clickAction: nil,
            notificationID: UUID())
        return true
    }
    @MainActor
    func clearSemanticFeedNotification(requestId: String) {
        let store = TerminalNotificationStore.shared
        for notification in store.notifications where notification.correlationKey == requestId {
            guard let surfaceID = notification.surfaceId else { continue }
            store.clearNotifications(forTabId: notification.tabId, surfaceId: surfaceID,
                correlationKey: requestId)
        }
    }

    /// Feed frames are normalized on the existing journal worker, not the UI actor.
    @MainActor
    func observeSemanticLifecycle(_ event: WorkstreamEvent) {
        switch event.hookEventName {
        case .sessionStart, .sessionEnd, .userPromptSubmit, .subagentStart, .subagentStop, .postToolUse:
            notificationJournal.observeFeed(AgentFeedSemanticInput(event: event,
                agentKey: Self.lifecycleStatusKey(forSource: event.source)))
        default:
            break
        }
    }
}
