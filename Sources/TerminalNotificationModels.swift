import Foundation

enum NotificationAuthorizationState: Equatable {
    case unknown
    case notDetermined
    case authorized
    case denied
    case provisional
    case ephemeral

    var statusLabel: String {
        switch self {
        case .unknown, .notDetermined:
            return "Not Requested"
        case .authorized:
            return "Allowed"
        case .denied:
            return "Denied"
        case .provisional:
            return "Deliver Quietly"
        case .ephemeral:
            return "Temporary"
        }
    }

    var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .unknown, .notDetermined, .denied:
            return false
        }
    }
}

enum TerminalNotificationAction: Hashable {
    case agentHookSetup(agentName: String)
}

struct TerminalNotification: Identifiable, Hashable {
    let id: UUID
    let tabId: UUID
    let surfaceId: UUID?
    let title: String
    let subtitle: String
    let body: String
    let action: TerminalNotificationAction?
    let createdAt: Date
    var isRead: Bool

    init(
        id: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String,
        action: TerminalNotificationAction? = nil,
        createdAt: Date,
        isRead: Bool
    ) {
        self.id = id
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.action = action
        self.createdAt = createdAt
        self.isRead = isRead
    }
}

