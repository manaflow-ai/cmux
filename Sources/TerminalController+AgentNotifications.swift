import CMUXAgentLaunch
import CmuxSettings
import Foundation
import os

/// Dedupes opencode turn-complete banners. The opencode plugin maps every
/// `session.idle` callback to a `Stop` feed event with no turn identity, so a
/// replayed idle for the same turn would re-notify. One fingerprint
/// (session + message text) is kept per surface; a repeat is dropped.
final class OpenCodeStopNotificationDeduper: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [UUID: String]())
    private let capacity: Int

    init(capacity: Int = 512) {
        self.capacity = max(1, capacity)
    }

    /// Atomically records `fingerprint` for `surfaceId` and reports whether it
    /// changed. The map is bounded: at `capacity` entries it resets, which at
    /// worst re-notifies one turn per evicted surface.
    func shouldNotify(surfaceId: UUID, fingerprint: String) -> Bool {
        state.withLock { map in
            if map[surfaceId] == fingerprint { return false }
            if map[surfaceId] == nil, map.count >= capacity { map.removeAll() }
            map[surfaceId] = fingerprint
            return true
        }
    }
}

extension TerminalController {
    private static let opencodeStopNotificationDeduper = OpenCodeStopNotificationDeduper()

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

        let fingerprint = [
            event.sessionId,
            event.assistantFinalMessage ?? "",
            event.context?.lastUserMessage ?? "",
        ].joined(separator: "|")
        guard Self.opencodeStopNotificationDeduper.shouldNotify(
            surfaceId: surfaceId,
            fingerprint: fingerprint
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
