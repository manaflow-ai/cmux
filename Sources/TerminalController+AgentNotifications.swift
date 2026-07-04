import CmuxSettings
import Foundation

extension TerminalController {
    nonisolated func v2PostOpenCodeStopNotificationIfNeeded(for event: WorkstreamEvent) {
        guard event.hookEventName == .stop,
              event.source == "opencode",
              let rawWorkspaceId = event.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              let rawSurfaceId = event.surfaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              let tabId = UUID(uuidString: rawWorkspaceId),
              let surfaceId = UUID(uuidString: rawSurfaceId) else {
            return
        }

        let catalog = NotificationsCatalogSection()
        let turnMode = AgentTurnCompleteMode(rawValue: catalog.agentTurnComplete.value(in: .standard)) ?? .whenIdle
        guard agentNotificationShouldDeliver(
            category: .turnComplete,
            pending: false,
            permissionEnabled: catalog.agentPermissionPrompt.value(in: .standard),
            turnMode: turnMode,
            idleEnabled: catalog.agentIdleReminder.value(in: .standard)
        ) else {
            return
        }

        let title = String(localized: "agentSession.provider.opencode", defaultValue: "OpenCode")
        let subtitle = String(localized: "agent.generic.notification.subtitle.completed", defaultValue: "Completed")
        let promptBody = NotificationBannerComposer.notificationBannerSnippet(event.context?.lastUserMessage, maxLength: 120).map { prompt in
            String.localizedStringWithFormat(
                String(localized: "agent.generic.completion.body.finishedPrompt", defaultValue: "Finished: %@"),
                prompt
            )
        }
        let assistantBody = NotificationBannerComposer.assistantMessageSnippetRejectingJSONBlob(
            event.assistantFinalMessage,
            maxLength: 180
        )
        let body = assistantBody
            ?? promptBody
            ?? String(localized: "agent.opencode.completion.body.sessionCompleted", defaultValue: "OpenCode session completed")

        TerminalMutationBus.shared.enqueueNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            agentId: "opencode",
            coalesces: false
        )
    }
}
