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
    let sequence: UInt64
    let generation: UInt64
}

fileprivate final class TerminalNotificationIngress: @unchecked Sendable {
    static let shared = TerminalNotificationIngress()

    private let lock = NSLock()
    private var queuedNotifications: [QueuedTerminalNotificationKey: QueuedTerminalNotification] = [:]
    private var scheduledGenerations = Set<UInt64>()
    private var currentGeneration: UInt64 = 0
    private var nextSequence: UInt64 = 0

    func enqueue(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String
    ) {
        let shouldScheduleDrain: Bool
        let generation: UInt64
        let key = QueuedTerminalNotificationKey(tabId: tabId, surfaceId: surfaceId)
        lock.lock()
        generation = currentGeneration
        nextSequence &+= 1
        queuedNotifications[key] = QueuedTerminalNotification(
            key: key,
            title: title,
            subtitle: subtitle,
            body: body,
            sequence: nextSequence,
            generation: generation
        )

        if scheduledGenerations.contains(generation) {
            shouldScheduleDrain = false
        } else {
            scheduledGenerations.insert(generation)
            shouldScheduleDrain = true
        }
        lock.unlock()

        guard shouldScheduleDrain else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.drainOnMainActor(generation: generation)
            }
        }
    }

    func discardAll() {
        lock.lock()
        queuedNotifications.removeAll(keepingCapacity: true)
        currentGeneration &+= 1
        lock.unlock()
    }

    func discard(tabId: UUID) {
        lock.lock()
        let keysToRemove = queuedNotifications.keys.filter { $0.tabId == tabId }
        for key in keysToRemove {
            queuedNotifications.removeValue(forKey: key)
        }
        currentGeneration &+= 1
        lock.unlock()
    }

    func discard(tabId: UUID, surfaceId: UUID?) {
        lock.lock()
        queuedNotifications.removeValue(forKey: QueuedTerminalNotificationKey(
            tabId: tabId,
            surfaceId: surfaceId
        ))
        currentGeneration &+= 1
        lock.unlock()
    }

    func discard(tabId: UUID, throughGeneration generation: UInt64) {
        lock.lock()
        let keysToRemove = queuedNotifications.compactMap { key, notification in
            key.tabId == tabId && notification.generation <= generation ? key : nil
        }
        for key in keysToRemove {
            queuedNotifications.removeValue(forKey: key)
        }
        lock.unlock()
    }

    func markClearBoundary() -> UInt64 {
        lock.lock()
        let generation = currentGeneration
        currentGeneration &+= 1
        lock.unlock()
        return generation
    }

#if DEBUG
    @MainActor
    func drainForTesting() {
        while true {
            lock.lock()
            let generations = scheduledGenerations.sorted()
            lock.unlock()

            guard let generation = generations.first else { return }
            drainOnMainActor(generation: generation)
        }
    }
#endif

    @MainActor
    private func drainOnMainActor(generation: UInt64) {
        while true {
            lock.lock()
            let queued = queuedNotifications.values
                .filter { $0.generation == generation }
                .sorted { $0.sequence < $1.sequence }
            guard !queued.isEmpty else {
                scheduledGenerations.remove(generation)
                lock.unlock()
                return
            }
            for notification in queued {
                if queuedNotifications[notification.key]?.generation == generation {
                    queuedNotifications.removeValue(forKey: notification.key)
                }
            }
            lock.unlock()

            TerminalNotificationStore.shared.deliverQueuedNotifications(queued)
        }
    }
}

extension TerminalNotificationStore {
    nonisolated static func enqueueNotification(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String
    ) {
        TerminalNotificationIngress.shared.enqueue(
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body
        )
    }

    nonisolated static func discardAllQueuedNotifications() {
        TerminalNotificationIngress.shared.discardAll()
    }

    nonisolated static func discardQueuedNotifications(forTabId tabId: UUID) {
        TerminalNotificationIngress.shared.discard(tabId: tabId)
    }

    nonisolated static func discardQueuedNotifications(forTabId tabId: UUID, surfaceId: UUID?) {
        TerminalNotificationIngress.shared.discard(tabId: tabId, surfaceId: surfaceId)
    }

    nonisolated static func discardQueuedNotifications(forTabId tabId: UUID, throughGeneration generation: UInt64) {
        TerminalNotificationIngress.shared.discard(tabId: tabId, throughGeneration: generation)
    }

    nonisolated static func markQueuedNotificationClearBoundary() -> UInt64 {
        TerminalNotificationIngress.shared.markClearBoundary()
    }

#if DEBUG
    static func drainQueuedNotificationsForTesting() {
        TerminalNotificationIngress.shared.drainForTesting()
    }
#endif

    fileprivate func deliverQueuedNotifications(_ queued: [QueuedTerminalNotification]) {
        for notification in queued {
            guard shouldDeliverQueuedNotification(notification) else { continue }
            addNotification(
                tabId: notification.key.tabId,
                surfaceId: notification.key.surfaceId,
                title: notification.title,
                subtitle: notification.subtitle,
                body: notification.body
            )
        }
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
            return true
        case .denied:
            return false
        case .notDetermined:
            return isAppActive ? nil : false
        case .unknown:
            return nil
        }
    }
}
