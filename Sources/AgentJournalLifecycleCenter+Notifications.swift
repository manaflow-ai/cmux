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
        }
    }

    @MainActor
    static func notificationTargetIsCurrent(_ draft: AgentJournalEventDraft) -> Bool {
        guard let workspaceID = draft.workspaceId.flatMap(UUID.init(uuidString:)),
              let surfaceID = draft.surfaceId.flatMap(UUID.init(uuidString:)),
              let live = AppDelegate.shared?.agentNotificationDeliveryTarget(
                claimedTabId: workspaceID, surfaceId: surfaceID),
              let panelID = live.surfaceId else {
            notificationDiagnostic(draft, reason: "route-unavailable")
            return false
        }
        if let workspace = AppDelegate.shared?.workspaceContainingPanel(
            panelId: panelID, preferredWorkspaceId: live.tabId)?.workspace,
           let binding = workspace.surfaceResumeBindingsByPanelId[panelID],
           binding.isAgentHookBinding, let sessionID = binding.checkpointId,
           sessionID != draft.sessionId {
            notificationDiagnostic(draft, reason: "session-superseded")
            return false
        }
        return true
    }

    @MainActor
    static func deliverNotification(_ event: AgentJournalEvent, identity: String) {
        let draft = event.draft
        guard let notification = draft.attention?.notification,
              let workspaceID = draft.workspaceId.flatMap(UUID.init(uuidString:)),
              let surfaceID = draft.surfaceId.flatMap(UUID.init(uuidString:)),
              let live = AppDelegate.shared?.agentNotificationDeliveryTarget(
                claimedTabId: workspaceID, surfaceId: surfaceID),
              let liveSurfaceID = live.surfaceId else {
            notificationDiagnostic(draft, reason: "route-unavailable", identity: identity)
            return
        }
        if let workspace = AppDelegate.shared?.workspaceContainingPanel(
            panelId: liveSurfaceID, preferredWorkspaceId: live.tabId)?.workspace,
           let binding = workspace.surfaceResumeBindingsByPanelId[liveSurfaceID],
           binding.isAgentHookBinding,
           let sessionID = binding.checkpointId, sessionID != draft.sessionId {
            notificationDiagnostic(draft, reason: "session-superseded", identity: identity)
            return
        }
        let category = AgentNotifyCategory(rawValue: notification.category)
        let alert: NotificationSoundAlertType? = draft.kind == .errorReported ? .errorStalled : category?.soundAlertType
        let sound = alert.flatMap { NotificationSoundOverrideContext(agentID: draft.source, alertType: $0) }
        let delivered = AgentNotificationDelivery().enqueue(
            workspaceID: live.tabId, surfaceID: liveSurfaceID,
            title: notification.title, subtitle: notification.subtitle, body: notification.body,
            category: category, pending: draft.pendingWork, soundContext: sound,
            agentKind: draft.source, isSubagent: draft.isSubagent,
            correlationKey: notification.correlationKey ?? identity,
            coalesces: false
        )
        if !delivered { notificationDiagnostic(draft, reason: "preference-filtered", identity: identity) }
    }

    static func notificationDiagnostic(_ draft: AgentJournalEventDraft, reason: String, identity: String? = nil) {
        CmuxEventBus.shared.publish(name: "agent.notification.decision", category: "agent", source: "journal",
            surfaceId: draft.surfaceId, payload: ["reason": reason, "kind": draft.kind.rawValue,
                "agent": draft.source, "identity": identity ?? "", "event_id": draft.eventId])
    }
}
