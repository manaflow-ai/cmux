import CmuxRemoteSession
import Foundation
fileprivate struct QueuedTerminalNotificationKey: Hashable, Sendable {
    let tabId: UUID
    let surfaceId: UUID?
}

fileprivate struct QueuedTerminalNotification: Sendable {
    let id: UUID
    let acceptedAt: Date
    let key: QueuedTerminalNotificationKey
    let title: String
    let subtitle: String
    let body: String
}

fileprivate enum TerminalSocketMutation {
    case deliverNotification(QueuedTerminalNotification)
    case clearAllNotifications
    case clearNotificationsForTab(UUID)
    case clearNotificationsForSurface(UUID, UUID)
    case perform(@MainActor () -> Void)
}

fileprivate struct TerminalSocketMutationEntry {
    let sequence: UInt64
    let mutation: TerminalSocketMutation
    let notificationGeneration: UInt64?
    let performReplaceKey: TerminalMutationReplaceKey?
}

final class TerminalMutationBus: @unchecked Sendable {
    static let shared = TerminalMutationBus()
    static let maximumPendingMutationCount = 256

    private let lock = NSCondition()
    private var pending: [TerminalSocketMutationEntry] = []
    private var pendingHead = 0
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
        body: String,
        backpressure: () -> Void
    ) {
        let notification = QueuedTerminalNotification(
            id: UUID(),
            acceptedAt: Date(),
            key: QueuedTerminalNotificationKey(tabId: tabId, surfaceId: surfaceId),
            title: title,
            subtitle: subtitle,
            body: body
        )
        while !tryEnqueueNotification(notification) {
            backpressure()
        }
    }

    nonisolated func enqueueClearAllNotifications() {
        enqueueClear(.clearAllNotifications) { _ in true }
    }
    nonisolated func enqueueClearNotifications(forTabId tabId: UUID) {
        enqueueClear(.clearNotificationsForTab(tabId)) { notification in
            notification.key.tabId == tabId
        }
    }

    nonisolated func enqueueClearNotifications(forTabId tabId: UUID, surfaceId: UUID) {
        enqueueClear(.clearNotificationsForSurface(tabId, surfaceId)) { notification in
            notification.key.tabId == tabId && notification.key.surfaceId == surfaceId
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

    nonisolated func discardPendingNotifications(forTabId tabId: UUID, surfaceId: UUID, through boundary: UInt64) {
        discardPendingNotifications { notification, generation in
            notification.key.tabId == tabId
                && notification.key.surfaceId == surfaceId
                && generation <= boundary
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

    private func tryEnqueueNotification(_ notification: QueuedTerminalNotification) -> Bool {
        let shouldScheduleDrain: Bool
        let pendingCount: Int
        let sequence: UInt64
        let generation: UInt64
        lock.lock()
        guard pending.count - pendingHead < Self.maximumPendingMutationCount else {
            lock.unlock()
            return false
        }
        generation = currentNotificationGeneration
        nextSequence &+= 1
        sequence = nextSequence
        pending.append(TerminalSocketMutationEntry(
            sequence: sequence,
            mutation: .deliverNotification(notification),
            notificationGeneration: generation,
            performReplaceKey: nil
        ))
        shouldScheduleDrain = !drainScheduled
        if shouldScheduleDrain {
            drainScheduled = true
        }
        pendingCount = pending.count - pendingHead
        lock.unlock()
#if DEBUG
        cmuxDebugLog(
            "notification.queue.enqueue seq=\(sequence) workspace=\(notification.key.tabId.uuidString.prefix(8)) surface=\(notification.key.surfaceId?.uuidString.prefix(8) ?? "nil") pending=\(pendingCount) generation=\(generation) titleLen=\(notification.title.count) subtitleLen=\(notification.subtitle.count) bodyLen=\(notification.body.count)"
        )
#endif
        if shouldScheduleDrain {
            scheduleDrain()
        }
        return true
    }

    /// Suspends a producer on the queue's capacity signal. The main-actor
    /// drain broadcasts after removing a FIFO batch, so saturation never
    /// requires a synchronous worker-to-main hop.
    nonisolated func waitForNotificationCapacity() {
        lock.lock()
        while pending.count - pendingHead >= Self.maximumPendingMutationCount {
            lock.wait()
        }
        lock.unlock()
    }

    private func enqueueClear(
        _ mutation: TerminalSocketMutation,
        dropping shouldDrop: (QueuedTerminalNotification) -> Bool
    ) {
        let shouldScheduleDrain: Bool
        lock.lock()
        compactPendingForMutation()
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
            notificationGeneration: nil,
            performReplaceKey: nil
        ))
        shouldScheduleDrain = !drainScheduled
        if shouldScheduleDrain {
            drainScheduled = true
        }
        lock.broadcast()
        lock.unlock()
        guard shouldScheduleDrain else { return }
        scheduleDrain()
    }

    private func enqueueBarrierMutation(_ mutation: TerminalSocketMutation) {
        let shouldScheduleDrain: Bool
        lock.lock()
        compactPendingForMutation()
        nextSequence &+= 1
        pending.append(TerminalSocketMutationEntry(
            sequence: nextSequence,
            mutation: mutation,
            notificationGeneration: nil,
            performReplaceKey: nil
        ))
        shouldScheduleDrain = !drainScheduled
        if shouldScheduleDrain {
            drainScheduled = true
        }
        lock.unlock()
        guard shouldScheduleDrain else { return }
        scheduleDrain()
    }

    /// Last-write-wins `enqueueMainActorMutation`: drops any still-pending
    /// mutation with the same `replaceKey` before appending, so the survivor
    /// applies at its new enqueue position.
    nonisolated func enqueueReplacingMainActorMutation(
        replaceKey: TerminalMutationReplaceKey,
        _ mutation: @escaping @MainActor () -> Void
    ) {
        let shouldScheduleDrain: Bool
        lock.lock()
        compactPendingForMutation()
        pending.removeAll { $0.performReplaceKey == replaceKey }
        nextSequence &+= 1
        pending.append(TerminalSocketMutationEntry(
            sequence: nextSequence,
            mutation: .perform(mutation),
            notificationGeneration: nil,
            performReplaceKey: replaceKey
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
        compactPendingForMutation()
        pending.removeAll { entry in
            guard case .deliverNotification(let notification) = entry.mutation,
                  let generation = entry.notificationGeneration else {
                return false
            }
            return shouldDiscard(notification, generation)
        }
        if advanceGeneration {
            currentNotificationGeneration &+= 1
        }
        lock.broadcast()
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
        shouldScheduleDrain = !suspended && drainScheduled && pendingHead < pending.count
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

    /// Applies one bounded FIFO batch when a socket producer reaches the queue
    /// limit. The producer does not receive `OK` until its notification has a
    /// slot, so accepted events remain lossless without unbounded buffering.
    @MainActor
    func drainForBackpressure() {
        drainOnMainActor()
    }

    @MainActor
    private func drainOnMainActor() {
        let batch = takeNextBatch()
        guard !batch.isEmpty else {
            markDrainCompleteIfEmpty()
            return
        }

        perform(batch)

        lock.lock()
        let hasMore = pendingHead < pending.count
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
        let count = min(maxMutationsPerDrain, pending.count - pendingHead)
        let batch: [TerminalSocketMutationEntry]
        if count > 0 {
            let end = pendingHead + count
            batch = Array(pending[pendingHead..<end])
            pendingHead = end
            compactPendingAfterDrain()
            lock.broadcast()
        } else {
            batch = []
        }
        let remaining = pending.count - pendingHead
        lock.unlock()
#if DEBUG
        if !batch.isEmpty {
            cmuxDebugLog(
                "notification.queue.drain batch=\(batch.count) remaining=\(remaining) firstSeq=\(batch.first?.sequence ?? 0) lastSeq=\(batch.last?.sequence ?? 0)"
            )
        }
#endif
        return batch
    }

    private func markDrainCompleteIfEmpty() {
        lock.lock()
        if pendingHead == pending.count {
            drainScheduled = false
            lock.unlock()
            return
        }
        lock.unlock()
        scheduleDrain()
    }

    /// Occasionally compacts consumed storage, keeping FIFO drains amortized O(1).
    private func compactPendingAfterDrain() {
        if pendingHead == pending.count {
            pending.removeAll(keepingCapacity: true)
            pendingHead = 0
        } else if pendingHead >= 4_096, pendingHead * 2 >= pending.count {
            pending.removeFirst(pendingHead)
            pendingHead = 0
        }
    }

    /// Discards the consumed prefix before mutations scan live work.
    private func compactPendingForMutation() {
        guard pendingHead > 0 else { return }
        pending.removeFirst(pendingHead)
        pendingHead = 0
    }

    @MainActor
    private func perform(_ batch: [TerminalSocketMutationEntry]) {
        for entry in batch {
            switch entry.mutation {
            case .deliverNotification(let notification):
#if DEBUG
                cmuxDebugLog(
                    "notification.queue.perform seq=\(entry.sequence) workspace=\(notification.key.tabId.uuidString.prefix(8)) surface=\(notification.key.surfaceId?.uuidString.prefix(8) ?? "nil") titleLen=\(notification.title.count) subtitleLen=\(notification.subtitle.count) bodyLen=\(notification.body.count)"
                )
#endif
                TerminalNotificationStore.shared.deliverQueuedNotification(notification)
            case .clearAllNotifications:
                TerminalNotificationStore.shared.clearAll(discardQueuedNotifications: false)
            case .clearNotificationsForTab(let tabId):
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: tabId,
                    discardQueuedNotifications: false
                )
            case .clearNotificationsForSurface(let tabId, let surfaceId):
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: tabId,
                    surfaceId: surfaceId,
                    discardQueuedNotifications: false
                )
            case .perform(let mutation):
                mutation()
            }
        }
    }
}

extension TerminalNotificationStore {
    fileprivate func deliverQueuedNotification(_ notification: QueuedTerminalNotification) {
        guard shouldDeliverQueuedNotification(notification) else {
#if DEBUG
            cmuxDebugLog(
                "notification.queue.deliver.skip workspace=\(notification.key.tabId.uuidString.prefix(8)) surface=\(notification.key.surfaceId?.uuidString.prefix(8) ?? "nil") reason=targetMissing titleLen=\(notification.title.count) subtitleLen=\(notification.subtitle.count) bodyLen=\(notification.body.count)"
            )
#endif
            return
        }
#if DEBUG
        cmuxDebugLog(
            "notification.queue.deliver workspace=\(notification.key.tabId.uuidString.prefix(8)) surface=\(notification.key.surfaceId?.uuidString.prefix(8) ?? "nil") titleLen=\(notification.title.count) subtitleLen=\(notification.subtitle.count) bodyLen=\(notification.body.count)"
        )
#endif
        addNotification(
            id: notification.id,
            acceptedAt: notification.acceptedAt,
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

    /// Effects for the out-of-band fallback path, where cmux plays feedback
    /// itself because the OS will not deliver the banner.
    ///
    /// A user who explicitly turned cmux notifications off (`.denied`) asked
    /// for silence, so the direct `NSSound` fallback must not punch through
    /// the denial (https://github.com/manaflow-ai/cmux/issues/5650). Every
    /// other state keeps the audible fallback: fresh installs
    /// (`.notDetermined`) have expressed no preference, and granted states
    /// only reach the fallback when delivery itself failed.
    nonisolated static func fallbackEffects(
        _ effects: TerminalNotificationPolicyEffects,
        authorizationState: NotificationAuthorizationState
    ) -> TerminalNotificationPolicyEffects {
        guard authorizationState == .denied else { return effects }
        var silenced = effects
        silenced.sound = false
        return silenced
    }
}
