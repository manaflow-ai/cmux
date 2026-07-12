import Foundation

struct SessionNotificationSnapshot: Codable, Sendable {
    var id: UUID
    var title: String
    var subtitle: String
    var body: String
    var createdAt: TimeInterval
    var isRead: Bool
    var paneFlash: Bool?
    var scrollPosition: TerminalNotificationScrollPosition?
    var clickAction: TerminalNotificationClickAction?

    init(
        id: UUID,
        title: String,
        subtitle: String,
        body: String,
        createdAt: TimeInterval,
        isRead: Bool,
        paneFlash: Bool? = nil,
        scrollPosition: TerminalNotificationScrollPosition? = nil,
        clickAction: TerminalNotificationClickAction? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
        self.paneFlash = paneFlash
        self.scrollPosition = scrollPosition
        self.clickAction = clickAction
    }

    init(notification: TerminalNotification) {
        self.init(
            id: notification.id,
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body,
            createdAt: notification.createdAt.timeIntervalSince1970,
            isRead: notification.isRead,
            paneFlash: notification.paneFlash,
            scrollPosition: notification.scrollPosition,
            clickAction: notification.clickAction
        )
    }

    func terminalNotification(tabId: UUID, surfaceId: UUID?, panelId: UUID?) -> TerminalNotification {
        TerminalNotification(
            id: id,
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            title: title,
            subtitle: subtitle,
            body: body,
            createdAt: Date(timeIntervalSince1970: createdAt),
            isRead: isRead,
            paneFlash: paneFlash ?? true,
            scrollPosition: scrollPosition,
            clickAction: clickAction
        )
    }
}

extension TerminalNotificationStore {
    func transferSessionNotifications(
        fromTabId: UUID,
        toTabId: UUID,
        panelIdMap: [UUID: UUID]
    ) {
        let merged = Self.mergeRestoredSessionNotifications(
            existing: notifications,
            restored: [],
            tabId: toTabId,
            replacingTabId: fromTabId,
            panelIdMap: panelIdMap
        )
        applySessionNotificationMerge(merged)
    }

    nonisolated static func mergeRestoredSessionNotifications(
        existing: [TerminalNotification],
        restored: [TerminalNotification],
        tabId: UUID,
        replacingTabId: UUID?,
        panelIdMap: [UUID: UUID]
    ) -> [TerminalNotification] {
        var canonicalById: [UUID: TerminalNotification] = [:]
        for candidate in restored where candidate.tabId == tabId {
            if let canonical = canonicalById[candidate.id] {
                if notificationRestoreCanonicalPrecedes(candidate, canonical) {
                    canonicalById[candidate.id] = candidate
                }
            } else {
                canonicalById[candidate.id] = candidate
            }
        }

        var merged = existing
        if let replacingTabId {
            for index in merged.indices where merged[index].tabId == replacingTabId {
                let current = merged[index]
                let restoredLocation = canonicalById[current.id]
                let surfaceId = restoredLocation.map(\.surfaceId)
                    ?? current.surfaceId.flatMap { panelIdMap[$0] }
                let panelId = restoredLocation.map(\.panelId)
                    ?? current.panelId.flatMap { panelIdMap[$0] }
                merged[index] = current.replacingLocation(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    panelId: panelId
                )
            }
        }

        var knownIds = Set(merged.map(\.id))
        merged.append(contentsOf: canonicalById.values.filter { knownIds.insert($0.id).inserted })
        return merged.sorted(by: notificationSortPrecedes)
    }

    nonisolated static func notificationRestoreCanonicalPrecedes(
        _ lhs: TerminalNotification,
        _ rhs: TerminalNotification
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return notificationRestoreCanonicalPayloadKey(lhs)
            .lexicographicallyPrecedes(notificationRestoreCanonicalPayloadKey(rhs))
    }

    private nonisolated static func notificationRestoreCanonicalPayloadKey(
        _ notification: TerminalNotification
    ) -> [String] {
        let clickActionKey: [String]
        switch notification.clickAction {
        case .none:
            clickActionKey = ["0", ""]
        case .revealInFinder(let path):
            clickActionKey = ["1", path]
        }

        var key = [notification.id.uuidString, notification.tabId.uuidString]
        key.append(notification.surfaceId == nil ? "0" : "1")
        key.append(notification.surfaceId?.uuidString ?? "")
        key.append(notification.panelId == nil ? "0" : "1")
        key.append(notification.panelId?.uuidString ?? "")
        key.append(contentsOf: [notification.title, notification.subtitle, notification.body])
        key.append(notification.isRead ? "1" : "0")
        key.append(notification.paneFlash ? "1" : "0")
        key.append(notification.scrollPosition == nil ? "0" : "1")
        key.append(notification.scrollPosition.map { String($0.row) } ?? "")
        key.append(notification.scrollPosition?.totalRows == nil ? "0" : "1")
        key.append(notification.scrollPosition?.totalRows.map(String.init) ?? "")
        key.append(contentsOf: clickActionKey)
        return key
    }
}

private extension TerminalNotification {
    func replacingLocation(tabId: UUID, surfaceId: UUID?, panelId: UUID?) -> TerminalNotification {
        TerminalNotification(
            id: id,
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            title: title,
            subtitle: subtitle,
            body: body,
            createdAt: createdAt,
            isRead: isRead,
            paneFlash: paneFlash,
            scrollPosition: scrollPosition,
            clickAction: clickAction
        )
    }
}
