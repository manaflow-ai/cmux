import CmuxAgentJournal
import CmuxSettings
import Foundation

extension AgentJournalLifecycleCenter {
    static func claimNotification(_ event: AgentJournalEvent, decision: AgentNotificationDecision,
                                  store: AgentJournalStore) -> Bool {
        guard event.draft.attention?.notification != nil else { return false }
        guard decision.disposition == .accepted, let identity = decision.identity else {
            notificationDiagnostic(event.draft, reason: decision.disposition.rawValue)
            return false
        }
        do {
            let accepted = try store.claimNotification(identity: identity)
            notificationDiagnostic(event.draft, reason: accepted ? "accepted" : "deduplicated", identity: identity)
            return accepted
        } catch {
            notificationDiagnostic(event.draft, reason: "receipt-unavailable", identity: identity)
            return false
        }
    }

    static func clearInvalidatedNotifications(_ event: AgentJournalEvent, decision: AgentNotificationDecision) {
        guard let workspaceID = event.draft.workspaceId.flatMap(UUID.init(uuidString:)),
              let surfaceID = event.draft.surfaceId.flatMap(UUID.init(uuidString:)) else { return }
        for key in decision.invalidatedCorrelationKeys {
            TerminalMutationBus.shared.enqueueClearNotifications(forTabId: workspaceID,
                surfaceId: surfaceID, correlationKey: key)
            if let sessionID = event.draft.sessionId {
                FeedCoordinator.shared.invalidateSemanticRequest(requestId: key, source: event.draft.source, sessionId: sessionID)
            }
        }
    }

    @MainActor
    static func notificationTargetIsCurrent(_ draft: AgentJournalEventDraft) -> Bool {
        notificationTarget(draft) != nil
    }

    @MainActor
    private static func notificationTarget(_ draft: AgentJournalEventDraft) -> (tabId: UUID, surfaceId: UUID)? {
        guard let workspaceID = draft.workspaceId.flatMap(UUID.init(uuidString:)),
              let surfaceID = draft.surfaceId.flatMap(UUID.init(uuidString:)),
              let live = AppDelegate.shared?.agentNotificationDeliveryTarget(
                claimedTabId: workspaceID, surfaceId: surfaceID),
              let panelID = live.surfaceId else {
            notificationDiagnostic(draft, reason: "route-unavailable")
            return nil
        }
        let binding = DockSplitStore.liveStores.first { $0.containsPanel(panelID) }?
            .surfaceResumeBindingsByPanelId[panelID]
            ?? AppDelegate.shared?.workspaceContainingPanel(panelId: panelID,
                preferredWorkspaceId: live.tabId)?.workspace.surfaceResumeBindingsByPanelId[panelID]
        if let binding, binding.isAgentHookBinding {
            guard binding.checkpointId == draft.sessionId,
                  binding.kind == nil || binding.kind?.lowercased() == draft.source.lowercased() else {
                notificationDiagnostic(draft, reason: "session-superseded")
                return nil
            }
        } else {
            let active = SharedLiveAgentIndex.shared.index?.entryForStablePanel(
                workspaceId: live.tabId, panelId: panelID, revalidateProcessEvidence: false)
            guard let sessionID = draft.sessionId,
                  AgentResumeLiveness.hasLiveProcess(for: active, kind: draft.source, sessionId: sessionID) else {
                notificationDiagnostic(draft, reason: "session-unbound")
                return nil
            }
        }
        return (live.tabId, panelID)
    }

    @MainActor
    static func notificationAdmission(_ draft: AgentJournalEventDraft) -> AgentNotificationDelivery? {
        guard let notification = draft.attention?.notification,
              notificationTarget(draft) != nil else { return nil }
        let delivery = AgentNotificationDelivery()
        guard delivery.allows(category: AgentNotifyCategory(rawValue: notification.category), pending: draft.pendingWork) else {
            notificationDiagnostic(draft, reason: "preference-filtered")
            return nil
        }
        return delivery
    }

    @MainActor
    static func deliverNotification(_ event: AgentJournalEvent, identity: String,
                                    admission: AgentNotificationDelivery? = nil) {
        let draft = event.draft
        guard let notification = draft.attention?.notification,
              let delivery = admission ?? notificationAdmission(draft),
              let live = notificationTarget(draft) else { return }
        let liveSurfaceID = live.surfaceId
        let category = AgentNotifyCategory(rawValue: notification.category)
        let alert: NotificationSoundAlertType? = draft.kind == .errorReported ? .errorStalled : category?.soundAlertType
        let sound = alert.flatMap { NotificationSoundOverrideContext(agentID: draft.source, alertType: $0) }
        let delivered = delivery.enqueue(
            workspaceID: live.tabId, surfaceID: liveSurfaceID,
            title: notification.title, subtitle: notification.subtitle, body: notification.body,
            category: category, pending: draft.pendingWork, soundContext: sound,
            agentKind: draft.source, isSubagent: draft.isSubagent,
            correlationKey: notification.correlationKey ?? identity,
            sessionId: draft.sessionId,
            coalesces: false
        )
        if !delivered { notificationDiagnostic(draft, reason: "preference-filtered", identity: identity) }
    }

    @MainActor
    static func notificationRequestIsCurrent(_ request: TerminalNotificationPolicyRequest) -> Bool {
        guard let sessionID = request.agent?.sessionId, let surfaceID = request.surfaceId else { return true }
        return notificationTargetIsCurrent(AgentJournalEventDraft(kind: .stateChanged, occurredAtMs: 0,
            source: request.agent?.kind ?? "agent", agentKey: request.agent?.kind ?? "agent",
            sessionId: sessionID, workspaceId: request.tabId.uuidString, surfaceId: surfaceID.uuidString))
    }

    static func notificationDiagnostic(_ draft: AgentJournalEventDraft, reason: String, identity: String? = nil) {
        CmuxEventBus.shared.publish(name: "agent.notification.decision", category: "agent", source: "journal",
            surfaceId: draft.surfaceId, payload: ["reason": reason, "kind": draft.kind.rawValue,
                "agent": draft.source, "identity": identity ?? "", "event_id": draft.eventId])
    }
}
