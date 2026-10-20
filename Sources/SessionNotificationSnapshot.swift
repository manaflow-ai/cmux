import CmuxSettings
import Foundation

struct SessionNotificationSnapshot: Codable, Sendable {
    var id: UUID
    var title: String
    var subtitle: String
    var body: String
    var createdAt: TimeInterval
    var isRead: Bool
    var paneFlash: Bool?
    /// Optional so snapshots written before the flag existed still decode.
    var isAgentEvent: Bool?
    var retargetsToLiveSurfaceOwner: Bool?
    var correlationKey: String?
    var scrollPosition: TerminalNotificationScrollPosition?
    var clickAction: TerminalNotificationClickAction?
    /// Agent/alert identity used if a restored notification is redelivered.
    /// Optional keeps snapshots written before per-agent sounds compatible.
    var soundContext: NotificationSoundOverrideContext?
    var agentKind: String?
    var agentCategory: String?
    var agentSessionId: String?

    init(
        id: UUID,
        title: String,
        subtitle: String,
        body: String,
        createdAt: TimeInterval,
        isRead: Bool,
        paneFlash: Bool? = nil,
        isAgentEvent: Bool? = nil,
        retargetsToLiveSurfaceOwner: Bool? = nil,
        correlationKey: String? = nil,
        scrollPosition: TerminalNotificationScrollPosition? = nil,
        clickAction: TerminalNotificationClickAction? = nil,
        soundContext: NotificationSoundOverrideContext? = nil,
        agentKind: String? = nil,
        agentCategory: String? = nil,
        agentSessionId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
        self.paneFlash = paneFlash
        self.isAgentEvent = isAgentEvent
        self.retargetsToLiveSurfaceOwner = retargetsToLiveSurfaceOwner
        self.correlationKey = correlationKey
        self.scrollPosition = scrollPosition
        self.clickAction = clickAction
        self.soundContext = soundContext
        self.agentKind = agentKind
        self.agentCategory = agentCategory
        self.agentSessionId = agentSessionId
    }

    init(notification: TerminalNotification) {
        let persistedScrollPosition = notification.scrollPosition.map {
            TerminalNotificationScrollPosition(row: $0.row, totalRows: $0.totalRows)
        }
        self.init(
            id: notification.id,
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body,
            createdAt: notification.createdAt.timeIntervalSince1970,
            isRead: notification.isRead,
            paneFlash: notification.paneFlash,
            isAgentEvent: notification.isAgentEvent,
            retargetsToLiveSurfaceOwner: notification.retargetsToLiveSurfaceOwner,
            correlationKey: notification.correlationKey,
            scrollPosition: persistedScrollPosition,
            clickAction: notification.clickAction,
            soundContext: notification.soundContext,
            agentKind: notification.agentKind,
            agentCategory: notification.agentCategory,
            agentSessionId: notification.agentSessionId
        )
    }

    func terminalNotification(tabId: UUID, surfaceId: UUID?, panelId: UUID?) -> TerminalNotification {
        let restoredScrollPosition = scrollPosition.map {
            TerminalNotificationScrollPosition(row: $0.row, totalRows: $0.totalRows)
        }
        return TerminalNotification(
            id: id,
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner ?? true,
            correlationKey: correlationKey,
            title: title,
            subtitle: subtitle,
            body: body,
            createdAt: Date(timeIntervalSince1970: createdAt),
            isRead: isRead,
            // Unknown provenance restores as agent-produced so a legacy
            // banner cannot re-enter the mobile Feed; it stays in the
            // Notifications screen either way.
            isAgentEvent: isAgentEvent ?? true,
            paneFlash: paneFlash ?? true,
            scrollPosition: restoredScrollPosition,
            clickAction: clickAction,
            soundContext: soundContext,
            agentKind: agentKind,
            agentCategory: agentCategory,
            agentSessionId: agentSessionId
        )
    }
}
