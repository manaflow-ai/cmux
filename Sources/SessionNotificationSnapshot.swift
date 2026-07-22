import Foundation

struct SessionNotificationSnapshot: Codable, Sendable {
    var id: UUID
    var title: String
    var subtitle: String
    var body: String
    var createdAt: TimeInterval
    var isRead: Bool
    var paneFlash: Bool?
    var retargetsToLiveSurfaceOwner: Bool?
    var scrollPosition: TerminalNotificationScrollPosition?
    var clickAction: TerminalNotificationClickAction?
    var surfaceId: UUID?
    var panelId: UUID?

    init(
        id: UUID,
        title: String,
        subtitle: String,
        body: String,
        createdAt: TimeInterval,
        isRead: Bool,
        paneFlash: Bool? = nil,
        retargetsToLiveSurfaceOwner: Bool? = nil,
        scrollPosition: TerminalNotificationScrollPosition? = nil,
        clickAction: TerminalNotificationClickAction? = nil,
        surfaceId: UUID? = nil,
        panelId: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
        self.paneFlash = paneFlash
        self.retargetsToLiveSurfaceOwner = retargetsToLiveSurfaceOwner
        self.scrollPosition = scrollPosition
        self.clickAction = clickAction
        self.surfaceId = surfaceId
        self.panelId = panelId
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
            retargetsToLiveSurfaceOwner: notification.retargetsToLiveSurfaceOwner,
            scrollPosition: persistedScrollPosition,
            clickAction: notification.clickAction,
            surfaceId: notification.surfaceId,
            panelId: notification.panelId
        )
    }

    func terminalNotification(tabId: UUID, surfaceId: UUID?, panelId: UUID?) -> TerminalNotification {
        let restoredScrollPosition = scrollPosition.map {
            TerminalNotificationScrollPosition(row: $0.row, totalRows: $0.totalRows)
        }
        let normalizedText = TerminalNotificationStore.normalizedNotificationText(
            title: title,
            subtitle: subtitle,
            body: body
        )
        return TerminalNotification(
            id: id,
            tabId: tabId,
            surfaceId: surfaceId ?? self.surfaceId,
            panelId: panelId ?? self.panelId,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner ?? true,
            title: normalizedText.title,
            subtitle: normalizedText.subtitle,
            body: normalizedText.body,
            createdAt: Date(timeIntervalSince1970: createdAt),
            isRead: isRead,
            paneFlash: paneFlash ?? true,
            scrollPosition: restoredScrollPosition,
            clickAction: clickAction
        )
    }
}

struct SessionNotificationSnapshotIndex {
    private struct PanelKey: Hashable {
        let tabId: UUID
        let panelId: UUID
    }

    private struct AddressedNotification {
        let surfaceId: UUID?
        let panelId: UUID?
        let snapshot: SessionNotificationSnapshot
    }

    static let empty = SessionNotificationSnapshotIndex()

    private var workspaceByTabId: [UUID: [SessionNotificationSnapshot]] = [:]
    private var panelByKey: [PanelKey: [SessionNotificationSnapshot]] = [:]
    private var addressedByTabId: [UUID: [AddressedNotification]] = [:]

    init() {}

    init<Notifications: Sequence>(
        notifications: Notifications
    ) where Notifications.Element == TerminalNotification {
        for notification in notifications {
            let snapshot = SessionNotificationSnapshot(notification: notification)
            if notification.surfaceId == nil, notification.panelId == nil {
                workspaceByTabId[notification.tabId, default: []].append(snapshot)
                continue
            }
            addressedByTabId[notification.tabId, default: []].append(
                AddressedNotification(
                    surfaceId: notification.surfaceId,
                    panelId: notification.panelId,
                    snapshot: snapshot
                )
            )
            if let surfaceId = notification.surfaceId {
                panelByKey[PanelKey(tabId: notification.tabId, panelId: surfaceId), default: []].append(snapshot)
            }
            if let panelId = notification.panelId, panelId != notification.surfaceId {
                panelByKey[PanelKey(tabId: notification.tabId, panelId: panelId), default: []].append(snapshot)
            }
        }
    }

    func workspaceSnapshots(tabId: UUID) -> [SessionNotificationSnapshot] {
        workspaceByTabId[tabId] ?? []
    }

    func panelSnapshots(tabId: UUID, panelId: UUID) -> [SessionNotificationSnapshot] {
        panelByKey[PanelKey(tabId: tabId, panelId: panelId)] ?? []
    }

    func orphanedSnapshots(tabId: UUID, persistedPanelIds: Set<UUID>) -> [SessionNotificationSnapshot] {
        addressedByTabId[tabId]?.compactMap { addressed in
            if let surfaceId = addressed.surfaceId, persistedPanelIds.contains(surfaceId) {
                return nil
            }
            if let panelId = addressed.panelId, persistedPanelIds.contains(panelId) {
                return nil
            }
            return addressed.snapshot
        } ?? []
    }
}

extension TerminalNotificationStore {
    func restoreSessionNotifications(
        _ restoredNotifications: [TerminalNotification],
        forTabId tabId: UUID,
        replacingTabId: UUID? = nil,
        panelIdMap: [UUID: UUID] = [:],
        restoredExternalBannerOwnerIDs: Set<UUID> = [],
        inferLegacyExternalBannerOwners: Bool = false
    ) {
        clearFocusedReadIndicator(forTabId: tabId)
        let existing = Array(notifications)
        let merged = Self.mergeRestoredSessionNotifications(
            existing: existing,
            restored: restoredNotifications,
            tabId: tabId,
            replacingTabId: replacingTabId,
            panelIdMap: panelIdMap
        )
        let ownerIDs = inferLegacyExternalBannerOwners && restoredExternalBannerOwnerIDs.isEmpty
            ? Self.legacyExternalBannerOwnerIDs(from: restoredNotifications)
            : restoredExternalBannerOwnerIDs
        guard merged != existing || !ownerIDs.isEmpty else { return }
        applySessionNotificationMerge(
            merged,
            restoredExternalBannerOwnerIDs: ownerIDs
        )
    }

    func transferSessionNotifications(
        fromTabId: UUID,
        toTabId: UUID,
        panelIdMap: [UUID: UUID]
    ) {
        TerminalMutationBus.shared.transferPendingNotifications(
            fromTabId: fromTabId,
            toTabId: toTabId,
            panelIdMap: panelIdMap
        )
        transferSessionNotificationState(
            fromTabId: fromTabId,
            toTabId: toTabId,
            panelIdMap: panelIdMap
        )
        let merged = Self.mergeRestoredSessionNotifications(
            existing: Array(notifications),
            restored: [],
            tabId: toTabId,
            replacingTabId: fromTabId,
            panelIdMap: panelIdMap
        )
        applySessionNotificationMerge(merged)
    }

    nonisolated static func replacingWorkspaceId(
        in ids: Set<UUID>,
        from oldId: UUID,
        to newId: UUID
    ) -> Set<UUID> {
        var result = ids
        if result.remove(oldId) != nil { result.insert(newId) }
        return result
    }

    nonisolated static func legacyExternalBannerOwnerIDs(
        from notifications: [TerminalNotification]
    ) -> Set<UUID> {
        var latestBySurface: [TabSurfaceKey: TerminalNotification] = [:]
        for notification in notifications where !notification.isRead {
            let key = TabSurfaceKey(tabId: notification.tabId, surfaceId: notification.surfaceId)
            if latestBySurface[key].map({ notificationSortPrecedes(notification, $0) }) ?? true {
                latestBySurface[key] = notification
            }
        }
        return Set(latestBySurface.values.map(\.id))
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
        var didRemapExisting = false
        if let replacingTabId {
            for index in merged.indices where merged[index].tabId == replacingTabId {
                let current = merged[index]
                let restoredLocation = canonicalById[current.id]
                let surfaceId = restoredLocation.map(\.surfaceId)
                    ?? current.surfaceId.map { panelIdMap[$0] ?? $0 }
                let panelId = restoredLocation.map(\.panelId)
                    ?? current.panelId.map { panelIdMap[$0] ?? $0 }
                merged[index] = current.replacingLocation(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    panelId: panelId
                )
                didRemapExisting = true
            }
        }
        guard didRemapExisting || !canonicalById.isEmpty else { return existing }

        var knownIds = Set(merged.map(\.id))
        let additions = canonicalById.values
            .filter { knownIds.insert($0.id).inserted }
            .sorted(by: notificationSortPrecedes)
        guard !additions.isEmpty else { return merged }
        return mergeSortedNotifications(merged, additions)
    }

    private nonisolated static func mergeSortedNotifications(
        _ existing: [TerminalNotification],
        _ additions: [TerminalNotification]
    ) -> [TerminalNotification] {
        var merged: [TerminalNotification] = []
        merged.reserveCapacity(existing.count + additions.count)
        var existingIndex = 0
        var additionIndex = 0
        while existingIndex < existing.count || additionIndex < additions.count {
            if additionIndex == additions.count {
                merged.append(contentsOf: existing[existingIndex...])
                break
            }
            if existingIndex == existing.count {
                merged.append(contentsOf: additions[additionIndex...])
                break
            }
            if notificationSortPrecedes(additions[additionIndex], existing[existingIndex]) {
                merged.append(additions[additionIndex])
                additionIndex += 1
            } else {
                merged.append(existing[existingIndex])
                existingIndex += 1
            }
        }
        return merged
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
        key.append(notification.retargetsToLiveSurfaceOwner ? "1" : "0")
        key.append(contentsOf: [notification.title, notification.subtitle, notification.body])
        key.append(notification.isRead ? "1" : "0")
        key.append(notification.paneFlash ? "1" : "0")
        key.append(notification.scrollPosition == nil ? "0" : "1")
        key.append(notification.scrollPosition.map { String($0.row) } ?? "")
        key.append(notification.scrollPosition?.totalRows == nil ? "0" : "1")
        key.append(notification.scrollPosition?.totalRows.map(String.init) ?? "")
        key.append(notification.scrollPosition?.rowSpaceRevision == nil ? "0" : "1")
        key.append(notification.scrollPosition?.rowSpaceRevision.map(String.init) ?? "")
        key.append(contentsOf: clickActionKey)
        return key
    }
}

extension TerminalNotification {
    func replacingLocation(tabId: UUID, surfaceId: UUID?, panelId: UUID?) -> TerminalNotification {
        TerminalNotification(
            id: id,
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner,
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

extension TerminalMutationBus {
    nonisolated static func remappingPendingEntries(
        _ entries: [TerminalSocketMutationEntry],
        fromTabId: UUID,
        toTabId: UUID,
        panelIdMap: [UUID: UUID]
    ) -> [TerminalSocketMutationEntry] {
        entries.map { entry in
            TerminalSocketMutationEntry(
                sequence: entry.sequence,
                mutation: entry.mutation.replacingTarget(
                    fromTabId: fromTabId,
                    toTabId: toTabId,
                    panelIdMap: panelIdMap
                ),
                notificationGeneration: entry.notificationGeneration,
                performReplaceKey: entry.performReplaceKey
            )
        }
    }

    nonisolated static func remappingNotificationKey(
        _ key: QueuedTerminalNotificationKey,
        fromTabId: UUID,
        toTabId: UUID,
        panelIdMap: [UUID: UUID]
    ) -> QueuedTerminalNotificationKey {
        guard key.tabId == fromTabId else { return key }
        return QueuedTerminalNotificationKey(
            tabId: toTabId,
            surfaceId: key.surfaceId.map { panelIdMap[$0] ?? $0 }
        )
    }
}

private extension TerminalSocketMutation {
    func replacingTarget(
        fromTabId: UUID,
        toTabId: UUID,
        panelIdMap: [UUID: UUID]
    ) -> TerminalSocketMutation {
        switch self {
        case .deliverNotification(let notification) where notification.key.tabId == fromTabId:
            let surfaceId = notification.key.surfaceId.map { panelIdMap[$0] ?? $0 }
            return .deliverNotification(QueuedTerminalNotification(
                id: notification.id,
                acceptedAt: notification.acceptedAt,
                key: QueuedTerminalNotificationKey(tabId: toTabId, surfaceId: surfaceId),
                allowWorkspaceFallbackForValidatedSurface: notification.allowWorkspaceFallbackForValidatedSurface,
                title: notification.title,
                subtitle: notification.subtitle,
                body: notification.body,
                contentByteCount: notification.contentByteCount
            ))
        case .clearNotificationsForTab(let tabId, let boundary) where tabId == fromTabId:
            return .clearNotificationsForTab(toTabId, through: boundary)
        case .clearNotificationsForSurface(let tabId, let surfaceId, let boundary) where tabId == fromTabId:
            return .clearNotificationsForSurface(
                toTabId,
                panelIdMap[surfaceId] ?? surfaceId,
                through: boundary
            )
        default:
            return self
        }
    }
}
