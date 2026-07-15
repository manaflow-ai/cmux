import Foundation

/// Tracks the row that actually owns the native and phone banner for each
/// tab/surface. Feed chronology is a separate concern: restored rows may sort
/// ahead without ever displaying.
struct ExternalNotificationBannerOwnership {
    private var ownerByKey: [String: TerminalNotification] = [:]
    private var keyByOwnerID: [UUID: String] = [:]

    func owner(tabId: UUID, surfaceId: UUID?) -> TerminalNotification? {
        ownerByKey[SupersededPhoneDismissBuffer.key(tabId: tabId, surfaceId: surfaceId)]
    }

    func owners(tabId: UUID) -> [TerminalNotification] {
        ownerByKey.values.filter { $0.tabId == tabId }
    }

    func ownerIDs(tabId: UUID) -> [UUID] {
        owners(tabId: tabId).map(\.id).sorted { $0.uuidString < $1.uuidString }
    }

    mutating func setOwner(_ notification: TerminalNotification?) {
        guard let notification else { return }
        let key = Self.key(notification)
        if let previousKey = keyByOwnerID[notification.id], previousKey != key {
            ownerByKey.removeValue(forKey: previousKey)
        }
        if let replaced = ownerByKey[key], replaced.id != notification.id {
            keyByOwnerID.removeValue(forKey: replaced.id)
        }
        ownerByKey[key] = notification
        keyByOwnerID[notification.id] = key
    }

    mutating func clear(tabId: UUID, surfaceId: UUID?) {
        let key = SupersededPhoneDismissBuffer.key(tabId: tabId, surfaceId: surfaceId)
        if let removed = ownerByKey.removeValue(forKey: key) {
            keyByOwnerID.removeValue(forKey: removed.id)
        }
    }

    mutating func clear(tabId: UUID) {
        let keys = ownerByKey.compactMap { key, owner in
            owner.tabId == tabId ? key : nil
        }
        for key in keys {
            if let removed = ownerByKey.removeValue(forKey: key) {
                keyByOwnerID.removeValue(forKey: removed.id)
            }
        }
    }

    mutating func clear(id: UUID) {
        guard let key = keyByOwnerID.removeValue(forKey: id) else { return }
        if ownerByKey[key]?.id == id {
            ownerByKey.removeValue(forKey: key)
        }
    }

    mutating func clear(ids: [String]) {
        for id in ids.compactMap(UUID.init(uuidString:)) {
            clear(id: id)
        }
    }

    mutating func clearAll() {
        ownerByKey.removeAll()
        keyByOwnerID.removeAll()
    }

    /// Preserve live owners by stable notification id while rows move during
    /// restore, then restore only explicitly persisted owners. Chronology is
    /// never evidence that a native or phone banner was displayed.
    mutating func reconcile(
        previous: [TerminalNotification],
        merged: [TerminalNotification],
        restoredOwnerIDs: Set<UUID> = []
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
        replaceOwners(reconciled)

        let restoredOwners = restoredOwnerIDs.compactMap { mergedById[$0] }
            .sorted(by: TerminalNotificationStore.notificationSortPrecedes)
        for notification in restoredOwners {
            let key = Self.key(notification)
            if ownerByKey[key] == nil { setOwner(notification) }
        }
    }

    mutating func resetAssumingOwners(from notifications: [TerminalNotification]) {
        clearAll()
        for notification in notifications {
            let key = Self.key(notification)
            if ownerByKey[key] == nil { setOwner(notification) }
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
                guard existing.id != moved.id else { continue }
                if TerminalNotificationStore.notificationSortPrecedes(moved, existing) {
                    setOwner(moved)
                    displaced.append(existing)
                } else {
                    displaced.append(moved)
                }
            } else {
                setOwner(moved)
            }
        }
        return displaced
    }

    @discardableResult
    mutating func rebind(surfaceId: UUID, fromTabId: UUID, toTabId: UUID) -> TerminalNotification? {
        guard let owner = ownerMatching(tabId: fromTabId, surfaceId: surfaceId) else { return nil }
        guard owner.retargetsToLiveSurfaceOwner else { return nil }
        clear(id: owner.id)
        let moved = owner.replacingLocation(
            tabId: toTabId,
            surfaceId: owner.surfaceId,
            panelId: owner.panelId
        )
        if let existing = ownerMatching(tabId: toTabId, surfaceId: surfaceId) {
            guard existing.id != moved.id else { return nil }
            if TerminalNotificationStore.notificationSortPrecedes(moved, existing) {
                clear(id: existing.id)
                setOwner(moved)
                return existing
            }
            return moved
        }
        setOwner(moved)
        return nil
    }

    private static func key(_ notification: TerminalNotification) -> String {
        SupersededPhoneDismissBuffer.key(tabId: notification.tabId, surfaceId: notification.surfaceId)
    }

    private func ownerMatching(tabId: UUID, surfaceId: UUID?) -> TerminalNotification? {
        if let exact = owner(tabId: tabId, surfaceId: surfaceId) { return exact }
        return ownerByKey.values.first {
            $0.matches(tabId: tabId, surfaceId: surfaceId)
        }
    }

    private mutating func replaceOwners(_ owners: [String: TerminalNotification]) {
        ownerByKey = owners
        keyByOwnerID.removeAll(keepingCapacity: true)
        for (key, owner) in ownerByKey {
            keyByOwnerID[owner.id] = key
        }
    }
}
