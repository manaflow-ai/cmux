import Foundation

extension TerminalMutationBus {
    nonisolated func markNotificationClearBoundary() -> UInt64 {
        lock.lock()
        let boundary = currentNotificationGeneration
        currentNotificationGeneration &+= 1
        lock.unlock()
        return boundary
    }

    nonisolated func notificationGenerationSnapshot() -> UInt64 {
        lock.withLock { currentNotificationGeneration }
    }

    nonisolated func discardPendingNotifications(forTabId tabId: UUID, through boundary: UInt64) {
        discardPendingNotifications { key, generation in
            key.tabId == tabId && generation <= boundary
        }
    }

    nonisolated func discardPendingNotifications(
        forTabId tabId: UUID,
        surfaceId: UUID,
        through boundary: UInt64
    ) {
        discardPendingNotifications { key, generation in
            key.tabId == tabId && key.surfaceId == surfaceId && generation <= boundary
        }
    }

    nonisolated func discardPendingNotifications() {
        discardPendingNotifications(advanceGeneration: true) { _, _ in true }
    }

    nonisolated func discardPendingNotifications(forTabId tabId: UUID) {
        discardPendingNotifications { key, _ in key.tabId == tabId }
    }

    /// Exact enqueue-key discard for source-scoped operations.
    nonisolated func discardPendingNotifications(forTabId tabId: UUID, surfaceId: UUID?) {
        discardPendingNotifications { key, _ in
            key.tabId == tabId && key.surfaceId == surfaceId
        }
    }

    /// Canonical surface identity for clears and supersedes.
    nonisolated func discardPendingNotifications(forSurfaceId surfaceId: UUID) {
        discardPendingNotifications { key, _ in key.surfaceId == surfaceId }
    }

    @MainActor
    func discardPendingNotificationsForClear(tabId: UUID, surfaceId: UUID?) {
        if let surfaceId {
            discardPendingNotifications(forSurfaceId: surfaceId)
        } else {
            discardPendingNotificationsResolvingLiveOwner(forTabId: tabId)
        }
    }

    nonisolated func pendingNotificationAddressesSnapshot() -> [(
        sequence: UInt64,
        tabId: UUID,
        surfaceId: UUID?
    )] {
        lock.lock()
        defer { lock.unlock() }
        return pending[pendingHead...].compactMap { entry in
            guard case .deliverNotification(let notification) = entry.mutation else { return nil }
            return (entry.sequence, notification.key.tabId, notification.key.surfaceId)
        }
    }

    nonisolated func queuedNotificationAddressesSnapshot() -> [(
        id: UUID,
        tabId: UUID,
        surfaceId: UUID?
    )] {
        lock.lock()
        defer { lock.unlock() }
        var addresses = pending[pendingHead...].compactMap { entry -> (UUID, UUID, UUID?)? in
            guard case .deliverNotification(let notification) = entry.mutation else { return nil }
            return (notification.id, notification.key.tabId, notification.key.surfaceId)
        }
        addresses.append(contentsOf: reliableAdmissionsById.values.map {
            ($0.id, $0.key.tabId, $0.key.surfaceId)
        })
        return addresses
    }

    nonisolated func discardPendingNotifications(sequences: Set<UInt64>) {
        guard !sequences.isEmpty else { return }
        lock.lock()
        compactPendingForMutation()
        pending.removeAll { entry in
            guard case .deliverNotification = entry.mutation else { return false }
            return sequences.contains(entry.sequence)
        }
        lock.broadcast()
        lock.unlock()
    }

    nonisolated func discardQueuedNotifications(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        lock.lock()
        reliableAdmissionsById = reliableAdmissionsById.filter { !ids.contains($0.key) }
        compactPendingForMutation()
        pending.removeAll { entry in
            guard case .deliverNotification(let notification) = entry.mutation else { return false }
            return ids.contains(notification.id)
        }
        lock.broadcast()
        lock.unlock()
    }

    nonisolated func transferPendingNotifications(
        fromTabId: UUID,
        toTabId: UUID,
        panelIdMap: [UUID: UUID]
    ) {
        guard fromTabId != toTabId else { return }
        lock.lock()
        installNotificationReplacementRoute(
            fromTabId: fromTabId,
            toTabId: toTabId,
            panelIdMap: panelIdMap
        )
        compactPendingForMutation()
        pending = Self.remappingPendingEntries(
            pending,
            fromTabId: fromTabId,
            toTabId: toTabId,
            panelIdMap: panelIdMap
        ).map(notificationEntryFollowingReplacementRoutes)
        for id in reliableAdmissionsById.keys {
            guard var admission = reliableAdmissionsById[id] else { continue }
            admission.key = notificationKeyFollowingReplacementRoutes(admission.key)
            reliableAdmissionsById[id] = admission
        }
        lock.broadcast()
        lock.unlock()
    }

    func notificationKeyFollowingReplacementRoutes(
        _ original: QueuedTerminalNotificationKey
    ) -> QueuedTerminalNotificationKey {
        // All callers hold `lock`, making route installation, admission
        // capture, and pending enqueue one atomic routing boundary.
        var tabId = original.tabId
        var surfaceId = original.surfaceId
        var visitedReplacementTabIds: Set<UUID> = []
        var visitedLiveOwnerKeys: Set<String> = []
        while true {
            var changed = false
            while visitedReplacementTabIds.insert(tabId).inserted,
                  let route = notificationReplacementRoutesByTabId[tabId] {
                surfaceId = surfaceId.map { route.panelIdMap[$0] ?? $0 }
                tabId = route.toTabId
                changed = true
            }
            if let surfaceId,
               let liveOwnerTabId = notificationLiveOwnerTabIdBySurfaceId[surfaceId],
               liveOwnerTabId != tabId {
                let liveOwnerKey = "\(surfaceId.uuidString):\(liveOwnerTabId.uuidString)"
                guard visitedLiveOwnerKeys.insert(liveOwnerKey).inserted else { break }
                tabId = liveOwnerTabId
                changed = true
                continue
            }
            if !changed { break }
        }
        return QueuedTerminalNotificationKey(tabId: tabId, surfaceId: surfaceId)
    }

    nonisolated func routedNotificationKey(
        tabId: UUID,
        surfaceId: UUID?
    ) -> QueuedTerminalNotificationKey {
        lock.lock()
        defer { lock.unlock() }
        return notificationKeyFollowingReplacementRoutes(
            QueuedTerminalNotificationKey(tabId: tabId, surfaceId: surfaceId)
        )
    }

    nonisolated func rebindPendingNotifications(
        fromTabId: UUID,
        toTabId: UUID,
        surfaceId: UUID
    ) {
        guard fromTabId != toTabId else { return }
        lock.lock()
        installNotificationLiveOwnerRoute(surfaceId: surfaceId, toTabId: toTabId)
        compactPendingForMutation()
        pending = pending.map(notificationEntryFollowingReplacementRoutes)
        for id in reliableAdmissionsById.keys {
            guard var admission = reliableAdmissionsById[id] else { continue }
            admission.key = notificationKeyFollowingReplacementRoutes(admission.key)
            reliableAdmissionsById[id] = admission
        }
        lock.broadcast()
        lock.unlock()
    }

    nonisolated func removeNotificationLiveOwnerRoute(surfaceId: UUID) {
        lock.lock()
        notificationLiveOwnerTabIdBySurfaceId.removeValue(forKey: surfaceId)
        notificationLiveOwnerSurfaceOrder.removeAll { $0 == surfaceId }
        lock.broadcast()
        lock.unlock()
    }

    private func installNotificationReplacementRoute(
        fromTabId: UUID,
        toTabId: UUID,
        panelIdMap: [UUID: UUID]
    ) {
        notificationReplacementRoutesByTabId[fromTabId] = TerminalNotificationReplacementRoute(
            toTabId: toTabId,
            panelIdMap: panelIdMap
        )
        notificationReplacementRouteOrder.removeAll { $0 == fromTabId }
        notificationReplacementRouteOrder.append(fromTabId)
        while notificationReplacementRouteOrder.count > Self.maximumNotificationReplacementRouteCount {
            let retiredTabId = notificationReplacementRouteOrder.removeFirst()
            notificationReplacementRoutesByTabId.removeValue(forKey: retiredTabId)
        }
    }

    private func installNotificationLiveOwnerRoute(surfaceId: UUID, toTabId: UUID) {
        notificationLiveOwnerTabIdBySurfaceId[surfaceId] = toTabId
        notificationLiveOwnerSurfaceOrder.removeAll { $0 == surfaceId }
        notificationLiveOwnerSurfaceOrder.append(surfaceId)
        while notificationLiveOwnerSurfaceOrder.count > Self.maximumNotificationLiveOwnerRouteCount {
            let retiredSurfaceId = notificationLiveOwnerSurfaceOrder.removeFirst()
            notificationLiveOwnerTabIdBySurfaceId.removeValue(forKey: retiredSurfaceId)
        }
    }

    private func notificationEntryFollowingReplacementRoutes(
        _ entry: TerminalSocketMutationEntry
    ) -> TerminalSocketMutationEntry {
        let routedMutation: TerminalSocketMutation
        switch entry.mutation {
        case .deliverNotification(let notification):
            routedMutation = .deliverNotification(QueuedTerminalNotification(
                id: notification.id,
                acceptedAt: notification.acceptedAt,
                key: notificationKeyFollowingReplacementRoutes(notification.key),
                allowWorkspaceFallbackForValidatedSurface: notification.allowWorkspaceFallbackForValidatedSurface,
                title: notification.title,
                subtitle: notification.subtitle,
                body: notification.body
            ))
        case .clearNotificationsForTab(let tabId, let boundary):
            let routed = notificationKeyFollowingReplacementRoutes(
                QueuedTerminalNotificationKey(tabId: tabId, surfaceId: nil)
            )
            routedMutation = .clearNotificationsForTab(routed.tabId, through: boundary)
        case .clearNotificationsForSurface(let tabId, let surfaceId, let boundary):
            let routed = notificationKeyFollowingReplacementRoutes(
                QueuedTerminalNotificationKey(tabId: tabId, surfaceId: surfaceId)
            )
            routedMutation = .clearNotificationsForSurface(
                routed.tabId,
                routed.surfaceId ?? surfaceId,
                through: boundary
            )
        case .clearAllNotifications, .perform:
            routedMutation = entry.mutation
        }
        return TerminalSocketMutationEntry(
            sequence: entry.sequence,
            mutation: routedMutation,
            notificationGeneration: entry.notificationGeneration,
            performReplaceKey: entry.performReplaceKey
        )
    }

    private nonisolated func discardPendingNotifications(
        advanceGeneration: Bool = false,
        where shouldDiscard: (QueuedTerminalNotificationKey, UInt64) -> Bool
    ) {
        lock.lock()
        reliableAdmissionsById = reliableAdmissionsById.filter {
            !shouldDiscard($0.value.key, $0.value.notificationGeneration)
        }
        compactPendingForMutation()
        pending.removeAll { entry in
            guard case .deliverNotification(let notification) = entry.mutation,
                  let generation = entry.notificationGeneration else {
                return false
            }
            return shouldDiscard(notification.key, generation)
        }
        if advanceGeneration {
            currentNotificationGeneration &+= 1
        }
        lock.broadcast()
        lock.unlock()
    }
}
