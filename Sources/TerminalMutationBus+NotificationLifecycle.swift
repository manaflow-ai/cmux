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

    nonisolated func transferPendingNotifications(
        fromTabId: UUID,
        toTabId: UUID,
        panelIdMap: [UUID: UUID]
    ) {
        guard fromTabId != toTabId else { return }
        lock.lock()
        compactPendingForMutation()
        pending = Self.remappingPendingEntries(
            pending,
            fromTabId: fromTabId,
            toTabId: toTabId,
            panelIdMap: panelIdMap
        )
        let reliableIds = reliableAdmissionsById.compactMap { id, admission in
            admission.key.tabId == fromTabId ? id : nil
        }
        for id in reliableIds {
            guard var admission = reliableAdmissionsById[id] else { continue }
            admission.key = QueuedTerminalNotificationKey(
                tabId: toTabId,
                surfaceId: admission.key.surfaceId.map { panelIdMap[$0] ?? $0 }
            )
            reliableAdmissionsById[id] = admission
        }
        lock.broadcast()
        lock.unlock()
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
