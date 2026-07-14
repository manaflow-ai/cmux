import Foundation

/// Tracks the row that actually owns (or, after a cold restore, is assumed to
/// own) the native and phone banner for each tab/surface. Feed chronology is a
/// separate concern: restored rows may sort ahead without ever displaying.
struct ExternalNotificationBannerOwnership {
    private var ownerByKey: [String: TerminalNotification] = [:]

    func owner(tabId: UUID, surfaceId: UUID?) -> TerminalNotification? {
        ownerByKey[SupersededPhoneDismissBuffer.key(tabId: tabId, surfaceId: surfaceId)]
    }

    mutating func setOwner(_ notification: TerminalNotification?) {
        guard let notification else { return }
        ownerByKey[Self.key(notification)] = notification
    }

    mutating func clear(tabId: UUID, surfaceId: UUID?) {
        ownerByKey.removeValue(forKey: SupersededPhoneDismissBuffer.key(tabId: tabId, surfaceId: surfaceId))
    }

    mutating func clear(tabId: UUID) {
        ownerByKey = ownerByKey.filter { $0.value.tabId != tabId }
    }

    mutating func clear(id: UUID) {
        ownerByKey = ownerByKey.filter { $0.value.id != id }
    }

    mutating func clear(ids: [String]) {
        for id in ids.compactMap(UUID.init(uuidString:)) { clear(id: id) }
    }

    mutating func clearAll() {
        ownerByKey.removeAll()
    }

    /// Preserve owners by stable notification id while rows move during
    /// restore. Only keys consisting entirely of newly restored rows are
    /// seeded, representing banners that may have survived a cold relaunch.
    mutating func reconcile(
        previous: [TerminalNotification],
        merged: [TerminalNotification]
    ) {
        let mergedById = Dictionary(
            merged.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var reconciled: [String: TerminalNotification] = [:]
        for owner in ownerByKey.values.compactMap({ mergedById[$0.id] })
            .sorted(by: TerminalNotificationStore.notificationSortPrecedes) {
            let key = Self.key(owner)
            if reconciled[key] == nil { reconciled[key] = owner }
        }
        ownerByKey = reconciled

        let previousIds = Set(previous.map(\.id))
        let keysWithPreviousRows = Set(merged.lazy.filter { previousIds.contains($0.id) }.map(Self.key))
        for notification in merged where !keysWithPreviousRows.contains(Self.key(notification)) {
            let key = Self.key(notification)
            if ownerByKey[key] == nil { ownerByKey[key] = notification }
        }
    }

    mutating func resetAssumingOwners(from notifications: [TerminalNotification]) {
        ownerByKey.removeAll()
        for notification in notifications {
            let key = Self.key(notification)
            if ownerByKey[key] == nil { ownerByKey[key] = notification }
        }
    }

    @discardableResult
    mutating func transfer(
        fromTabId: UUID,
        toTabId: UUID,
        panelIdMap: [UUID: UUID]
    ) -> [TerminalNotification] {
        let moving = ownerByKey.values
            .filter { $0.tabId == fromTabId }
            .sorted(by: TerminalNotificationStore.notificationSortPrecedes)
        clear(tabId: fromTabId)
        var displaced: [TerminalNotification] = []
        for owner in moving {
            let surfaceId = owner.surfaceId.map { panelIdMap[$0] ?? $0 }
            let panelId = owner.panelId.map { panelIdMap[$0] ?? $0 }
            let moved = owner.replacingLocation(tabId: toTabId, surfaceId: surfaceId, panelId: panelId)
            if let existing = ownerByKey[Self.key(moved)] {
                if existing.id != moved.id { displaced.append(moved) }
            } else {
                setOwner(moved)
            }
        }
        return displaced
    }

    @discardableResult
    mutating func rebind(surfaceId: UUID, fromTabId: UUID, toTabId: UUID) -> TerminalNotification? {
        guard let owner = owner(tabId: fromTabId, surfaceId: surfaceId) else { return nil }
        clear(tabId: fromTabId, surfaceId: surfaceId)
        let moved = owner.replacingLocation(
            tabId: toTabId,
            surfaceId: owner.surfaceId,
            panelId: owner.panelId
        )
        if let existing = self.owner(tabId: toTabId, surfaceId: surfaceId) {
            return existing.id == moved.id ? nil : moved
        }
        setOwner(moved)
        return nil
    }

    private static func key(_ notification: TerminalNotification) -> String {
        SupersededPhoneDismissBuffer.key(tabId: notification.tabId, surfaceId: notification.surfaceId)
    }
}
