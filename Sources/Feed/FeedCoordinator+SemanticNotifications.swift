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
        let kind: AgentJournalEventKind = switch event.hookEventName {
        case .permissionRequest: .approvalRequested
        case .askUserQuestion: .questionRequested
        case .exitPlanMode: .planReviewRequested
        default: .stateChanged
        }
        let sessionID = FeedWorkstreamIdentifier(rawValue: event.sessionId)?.sessionID ?? event.sessionId
        let extra = event.extraFieldsJSON.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let nativeRequest = ["tool_use_id", "tool_call_id", "request_id"].compactMap { extra?[$0] as? String }.first
        let draft = AgentJournalEventDraft(kind: kind,
            occurredAtMs: Int64(event.receivedAt.timeIntervalSince1970 * 1000),
            source: event.source, agentKey: Self.lifecycleStatusKey(forSource: event.source),
            sessionId: sessionID, workspaceId: target.tabId.uuidString, surfaceId: liveSurfaceID.uuidString,
            nativeEvent: event.hookEventName.rawValue,
            attention: AgentAttentionContext(requestIdentity: nativeRequest ?? requestId,
                notification: AgentJournalNotification(title: title, subtitle: subtitle,
                    body: body, category: "needs-permission", correlationKey: requestId)))
        guard await notificationJournal.admitNotification(draft),
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
                category: "needs-permission", pending: false, isSubagent: false), soundContext: soundContext)
        guard AgentJournalLifecycleCenter.notificationTargetIsCurrent(draft) else { return false }
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

    /// Feed observations enter the same stream without creating another CLI/socket producer.
    @MainActor
    func observeSemanticLifecycle(_ event: WorkstreamEvent) {
        let kind = AgentSemanticEventMapper().kind(source: event.source,
            nativeEvent: event.hookEventName.rawValue)
        // Stop telemetry is not settlement evidence. The root/child lifecycle
        // adapter owns that assertion. Blocking requests are admitted only while
        // a real waiter remains, after automatic policy replies have had a chance.
        guard [.sessionStarted, .turnStarted, .sessionEnded, .childSpawned,
               .childCompleted, .childFailed].contains(kind) || event.hookEventName == .postToolUse else { return }
        guard let workspaceID = event.workspaceId, let surfaceID = event.surfaceId else { return }
        let extra = event.extraFieldsJSON.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let request = ["tool_use_id", "tool_call_id", "request_id", "agent_id"].compactMap { extra[$0] as? String }.first
        let resolved = event.hookEventName == .postToolUse
        guard !resolved || request != nil else { return }
        notificationJournal.observe(AgentJournalEventDraft(kind: resolved ? .stateChanged : kind,
            occurredAtMs: (extra["occurred_at_ms"] as? NSNumber)?.int64Value
                ?? Int64(event.receivedAt.timeIntervalSince1970 * 1000),
            source: event.source, agentKey: Self.lifecycleStatusKey(forSource: event.source),
            sessionId: FeedWorkstreamIdentifier(rawValue: event.sessionId)?.sessionID ?? event.sessionId,
            workspaceId: workspaceID, surfaceId: surfaceID, nativeEvent: event.hookEventName.rawValue,
            declaredPhase: resolved ? .running : nil,
            attention: AgentAttentionContext(eventIdentity: extra["event_id"] as? String,
                turnIdentity: extra["turn_id"] as? String, requestIdentity: request)))
    }
}
