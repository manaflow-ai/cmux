import Foundation

/// One durable cmux notification in the cross-device chronological feed.
struct NotificationFeedHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    static let historyTitleByteLimit = 512
    static let historySubtitleByteLimit = 512
    static let historyBodyByteLimit = 2_048

    let id: UUID
    var tabId: UUID
    var surfaceId: UUID?
    var panelId: UUID?
    let retargetsToLiveSurfaceOwner: Bool
    let title: String
    let subtitle: String
    let body: String
    let createdAt: Date
    var isRead: Bool

    init(
        id: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID?,
        retargetsToLiveSurfaceOwner: Bool,
        title: String,
        subtitle: String,
        body: String,
        createdAt: Date,
        isRead: Bool
    ) {
        self.id = id
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.panelId = panelId
        self.retargetsToLiveSurfaceOwner = retargetsToLiveSurfaceOwner
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
    }

    init(notification: TerminalNotification) {
        id = notification.id
        tabId = notification.tabId
        surfaceId = notification.surfaceId
        panelId = notification.panelId
        retargetsToLiveSurfaceOwner = notification.retargetsToLiveSurfaceOwner
        title = notification.title
        subtitle = notification.subtitle
        body = notification.body
        createdAt = notification.createdAt
        isRead = notification.isRead
    }

    func matches(tabId targetTabId: UUID, surfaceId targetSurfaceId: UUID?) -> Bool {
        guard tabId == targetTabId else { return false }
        guard let targetSurfaceId else {
            return surfaceId == nil && panelId == nil
        }
        return surfaceId == targetSurfaceId || panelId == targetSurfaceId
    }

    func boundedForHistory() -> NotificationFeedHistoryRecord {
        NotificationFeedHistoryRecord(
            id: id,
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner,
            title: Self.string(title, limitedToUTF8Bytes: Self.historyTitleByteLimit),
            subtitle: Self.string(subtitle, limitedToUTF8Bytes: Self.historySubtitleByteLimit),
            body: Self.string(body, limitedToUTF8Bytes: Self.historyBodyByteLimit),
            createdAt: createdAt,
            isRead: isRead
        )
    }

    private static func string(_ value: String, limitedToUTF8Bytes maxBytes: Int) -> String {
        guard maxBytes >= 0, value.utf8.count > maxBytes else { return value }
        var byteCount = 0
        var endIndex = value.startIndex
        while endIndex < value.endIndex {
            let nextIndex = value.index(after: endIndex)
            let characterByteCount = value[endIndex..<nextIndex].utf8.count
            guard byteCount + characterByteCount <= maxBytes else { break }
            byteCount += characterByteCount
            endIndex = nextIndex
        }
        return String(value[..<endIndex])
    }
}
