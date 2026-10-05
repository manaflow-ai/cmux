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
    @discardableResult
    func clearSemanticFeedNotification(
        requestId: String,
        source: String? = nil,
        sessionId: String? = nil,
        workspaceId: UUID? = nil,
        surfaceId: UUID? = nil
    ) -> Bool {
        let store = TerminalNotificationStore.shared
        let before = store.notifications.count
        for notification in store.notifications where notification.correlationKey == requestId {
            guard let notificationSurfaceID = notification.surfaceId else { continue }
            store.clearNotifications(forTabId: notification.tabId, surfaceId: notificationSurfaceID,
                correlationKey: requestId)
        }
        guard store.notifications.count == before else { return true }

        // Some older agent hooks did not carry a producer key. The later
        // same-session hook still identifies the prompt by agent and surface;
        // when that metadata is unavailable, only a single pending prompt is
        // safe to retire so a second unanswered prompt keeps its ring.
        let candidates = store.notifications.filter {
            !$0.isRead && $0.agentCategory == AgentNotifyCategory.needsPermission.rawValue &&
                (workspaceId == nil || $0.tabId == workspaceId) &&
                (surfaceId == nil || $0.surfaceId == surfaceId)
        }
        guard let source, let sessionId, let surfaceId,
              candidates.count == 1, let candidate = candidates.first,
              candidate.agentKind == source,
              candidate.agentSessionId == Self.normalizedAgentSessionId(source: source, rawValue: sessionId),
              candidate.surfaceId == surfaceId else { return false }
        let normalizedSessionId = Self.normalizedAgentSessionId(source: source, rawValue: sessionId)
        return store.clearAgentAttentionNotification(
            forTabId: candidate.tabId,
            surfaceId: surfaceId,
            agentKind: source,
            sessionId: normalizedSessionId
        )
    }

    private static func normalizedAgentSessionId(source: String, rawValue: String) -> String {
        let canonical = FeedWorkstreamIdentifier.canonicalizedRawValue(
            agentID: source,
            rawValue: rawValue
        )
        return FeedWorkstreamIdentifier(rawValue: canonical)?.sessionID ?? rawValue
    }

    /// Feed frames are normalized on the existing journal worker, not the UI actor.
    @MainActor
    func observeSemanticLifecycle(_ event: WorkstreamEvent) {
        switch event.hookEventName {
        case .sessionStart, .sessionEnd, .userPromptSubmit, .subagentStart, .subagentStop, .preToolUse, .postToolUse, .postToolUseFailure, .stop, .notification:
            notificationJournal.observeFeed(AgentFeedSemanticInput(event: event,
                agentKey: Self.lifecycleStatusKey(forSource: event.source)))
        default:
            break
        }
    }
}
