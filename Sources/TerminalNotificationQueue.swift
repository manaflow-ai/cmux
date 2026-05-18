import Foundation

fileprivate struct QueuedTerminalNotificationKey: Hashable, Sendable {
    let tabId: UUID
    let surfaceId: UUID?
}

fileprivate struct QueuedTerminalNotification: Sendable {
    let key: QueuedTerminalNotificationKey
    let title: String
    let subtitle: String
    let body: String
}

fileprivate enum TerminalSocketMutation {
    case deliverNotification(QueuedTerminalNotification)
    case clearAllNotifications
    case clearNotificationsForTab(UUID)
    case perform(@MainActor () -> Void)
}

fileprivate struct TerminalSocketMutationEntry {
    let sequence: UInt64
    let mutation: TerminalSocketMutation
    let notificationCoalescingKey: TerminalNotificationCoalescingKey?
}

fileprivate struct TerminalNotificationCoalescingKey: Hashable {
    let generation: UInt64
    let notificationKey: QueuedTerminalNotificationKey
}

final class TerminalMutationBus: @unchecked Sendable {
    static let shared = TerminalMutationBus()

    private let lock = NSLock()
    private var pending: [TerminalSocketMutationEntry] = []
    private var drainScheduled = false
    private var nextSequence: UInt64 = 0
    private var currentNotificationGeneration: UInt64 = 0
    private let maxMutationsPerDrain = 16
#if DEBUG
    private var drainsSuspendedForTesting = false
#endif

    nonisolated func enqueueNotification(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String
    ) {
        enqueueNotification(QueuedTerminalNotification(
            key: QueuedTerminalNotificationKey(tabId: tabId, surfaceId: surfaceId),
            title: title,
            subtitle: subtitle,
            body: body
        ))
    }

    nonisolated func enqueueClearAllNotifications() {
        enqueueClear(.clearAllNotifications) { _ in true }
    }

    nonisolated func enqueueClearNotifications(forTabId tabId: UUID) {
        enqueueClear(.clearNotificationsForTab(tabId)) { notification in
            notification.key.tabId == tabId
        }
    }

    nonisolated func enqueueMainActorMutation(_ mutation: @escaping @MainActor () -> Void) {
        enqueueBarrierMutation(.perform(mutation))
    }

    nonisolated func markNotificationClearBoundary() -> UInt64 {
        lock.lock()
        let boundary = currentNotificationGeneration
        currentNotificationGeneration &+= 1
        lock.unlock()
        return boundary
    }

    nonisolated func discardPendingNotifications(forTabId tabId: UUID, through boundary: UInt64) {
        discardPendingNotifications { notification, generation in
            notification.key.tabId == tabId && generation <= boundary
        }
    }

    nonisolated func discardPendingNotifications() {
        discardPendingNotifications(advanceGeneration: true) { _, _ in true }
    }

    nonisolated func discardPendingNotifications(forTabId tabId: UUID) {
        discardPendingNotifications { notification, _ in
            notification.key.tabId == tabId
        }
    }

    nonisolated func discardPendingNotifications(forTabId tabId: UUID, surfaceId: UUID?) {
        discardPendingNotifications { notification, _ in
            notification.key.tabId == tabId && notification.key.surfaceId == surfaceId
        }
    }

    private func enqueueNotification(_ notification: QueuedTerminalNotification) {
        let shouldScheduleDrain: Bool
        lock.lock()
        let coalescingKey = TerminalNotificationCoalescingKey(
            generation: currentNotificationGeneration,
            notificationKey: notification.key
        )
        pending.removeAll { entry in
            entry.notificationCoalescingKey == coalescingKey
        }
        nextSequence &+= 1
        pending.append(TerminalSocketMutationEntry(
            sequence: nextSequence,
            mutation: .deliverNotification(notification),
            notificationCoalescingKey: coalescingKey
        ))
        shouldScheduleDrain = !drainScheduled
        if shouldScheduleDrain {
            drainScheduled = true
        }
        lock.unlock()

        guard shouldScheduleDrain else { return }
        scheduleDrain()
    }

    private func enqueueClear(
        _ mutation: TerminalSocketMutation,
        dropping shouldDrop: (QueuedTerminalNotification) -> Bool
    ) {
        let shouldScheduleDrain: Bool
        lock.lock()
        pending.removeAll { entry in
            if case .deliverNotification(let notification) = entry.mutation {
                return shouldDrop(notification)
            }
            return false
        }
        nextSequence &+= 1
        pending.append(TerminalSocketMutationEntry(
            sequence: nextSequence,
            mutation: mutation,
            notificationCoalescingKey: nil
        ))
        shouldScheduleDrain = !drainScheduled
        if shouldScheduleDrain {
            drainScheduled = true
        }
        lock.unlock()

        guard shouldScheduleDrain else { return }
        scheduleDrain()
    }

    private func enqueueBarrierMutation(_ mutation: TerminalSocketMutation) {
        let shouldScheduleDrain: Bool
        lock.lock()
        nextSequence &+= 1
        pending.append(TerminalSocketMutationEntry(
            sequence: nextSequence,
            mutation: mutation,
            notificationCoalescingKey: nil
        ))
        shouldScheduleDrain = !drainScheduled
        if shouldScheduleDrain {
            drainScheduled = true
        }
        lock.unlock()

        guard shouldScheduleDrain else { return }
        scheduleDrain()
    }

    private func discardPendingNotifications(
        advanceGeneration: Bool = false,
        where shouldDiscard: (QueuedTerminalNotification, UInt64) -> Bool
    ) {
        lock.lock()
        pending.removeAll { entry in
            guard case .deliverNotification(let notification) = entry.mutation,
                  let coalescingKey = entry.notificationCoalescingKey else {
                return false
            }
            return shouldDiscard(notification, coalescingKey.generation)
        }
        if advanceGeneration {
            currentNotificationGeneration &+= 1
        }
        lock.unlock()
    }

    private func scheduleDrain() {
#if DEBUG
        lock.lock()
        let suspended = drainsSuspendedForTesting
        lock.unlock()
        if suspended { return }
#endif
        Task { @MainActor [weak self] in
            self?.drainOnMainActor()
        }
    }

#if DEBUG
    nonisolated func setDrainsSuspendedForTesting(_ suspended: Bool) {
        let shouldScheduleDrain: Bool
        lock.lock()
        drainsSuspendedForTesting = suspended
        shouldScheduleDrain = !suspended && drainScheduled && !pending.isEmpty
        lock.unlock()

        if shouldScheduleDrain {
            scheduleDrain()
        }
    }

    @MainActor
    func drainForTesting() {
        while true {
            let batch = takeNextBatch()
            guard !batch.isEmpty else {
                markDrainCompleteIfEmpty()
                return
            }
            perform(batch)
        }
    }
#endif

    @MainActor
    private func drainOnMainActor() {
        let batch = takeNextBatch()
        guard !batch.isEmpty else {
            markDrainCompleteIfEmpty()
            return
        }

        perform(batch)

        lock.lock()
        let hasMore = !pending.isEmpty
        if !hasMore {
            drainScheduled = false
        }
        lock.unlock()

        if hasMore {
            scheduleDrain()
        }
    }

    private func takeNextBatch() -> [TerminalSocketMutationEntry] {
        lock.lock()
        let count = min(maxMutationsPerDrain, pending.count)
        let batch = Array(pending.prefix(count))
        if !batch.isEmpty {
            pending.removeFirst(count)
        }
        lock.unlock()
        return batch
    }

    private func markDrainCompleteIfEmpty() {
        lock.lock()
        if pending.isEmpty {
            drainScheduled = false
            lock.unlock()
            return
        }
        lock.unlock()

        scheduleDrain()
    }

    @MainActor
    private func perform(_ batch: [TerminalSocketMutationEntry]) {
        for entry in batch {
            switch entry.mutation {
            case .deliverNotification(let notification):
                TerminalNotificationStore.shared.deliverQueuedNotification(notification)
            case .clearAllNotifications:
                TerminalNotificationStore.shared.clearAll(discardQueuedNotifications: false)
            case .clearNotificationsForTab(let tabId):
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: tabId,
                    discardQueuedNotifications: false
                )
            case .perform(let mutation):
                mutation()
            }
        }
    }
}

extension TerminalController {
    func deliverNotificationSynchronously(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String
    ) {
        TerminalMutationBus.shared.discardPendingNotifications(forTabId: tabId, surfaceId: surfaceId)
        TerminalNotificationStore.shared.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body
        )
    }
}

extension TerminalNotificationStore {
    fileprivate func deliverQueuedNotification(_ notification: QueuedTerminalNotification) {
        guard shouldDeliverQueuedNotification(notification) else { return }
        addNotification(
            tabId: notification.key.tabId,
            surfaceId: notification.key.surfaceId,
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body
        )
    }

    private func shouldDeliverQueuedNotification(_ notification: QueuedTerminalNotification) -> Bool {
        guard let appDelegate = AppDelegate.shared else { return false }
        guard let surfaceId = notification.key.surfaceId else {
            let tabManager = appDelegate.tabManagerFor(tabId: notification.key.tabId) ?? appDelegate.tabManager
            return tabManager?.tabs.contains(where: { $0.id == notification.key.tabId }) == true
        }

        guard let target = appDelegate.workspaceContainingPanel(
            panelId: surfaceId,
            preferredWorkspaceId: notification.key.tabId
        ) else {
            return false
        }
        return target.workspace.id == notification.key.tabId
    }

    static func cachedDeliveryAuthorizationDecision(
        for state: NotificationAuthorizationState,
        isAppActive: Bool
    ) -> Bool? {
        switch state {
        case .authorized, .provisional, .ephemeral:
            return nil
        case .denied:
            return false
        case .notDetermined:
            return isAppActive ? nil : false
        case .unknown:
            return nil
        }
    }
}
