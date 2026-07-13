import Foundation

final class TerminalMutationBus: @unchecked Sendable {
    static let shared = TerminalMutationBus()
    static let maximumPendingMutationCount = 256
    static let maximumWaitingNotificationProducerCount = 16
    static let notificationCapacityWaitTimeout: TimeInterval = 1

    private let lock = NSCondition()
    private var pending: [TerminalSocketMutationEntry] = []
    private var pendingHead = 0
    private var drainScheduled = false
    private var nextSequence: UInt64 = 0
    private var currentNotificationGeneration: UInt64 = 0
    private var waitingNotificationProducerCount = 0
    private var reliableAdmissionsById: [UUID: ReliableTerminalNotificationAdmission] = [:]
    private var reliablyWaitingNotificationProducerCount = 0
    private let maxMutationsPerDrain = 16
#if DEBUG
    private var drainsSuspendedForTesting = false
#endif

    @discardableResult
    nonisolated func enqueueNotification(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String,
        saturationHandler: (() -> Void)? = nil
    ) -> Bool {
        while true {
            lock.lock()
            if pending.count - pendingHead >= Self.maximumPendingMutationCount {
                if let saturationHandler {
                    lock.unlock()
                    saturationHandler()
                    continue
                }
                guard waitingNotificationProducerCount < Self.maximumWaitingNotificationProducerCount else {
                    lock.unlock()
                    return false
                }
                waitingNotificationProducerCount += 1
                let deadline = Date(timeIntervalSinceNow: Self.notificationCapacityWaitTimeout)
                while pending.count - pendingHead >= Self.maximumPendingMutationCount {
                    guard lock.wait(until: deadline) else {
                        waitingNotificationProducerCount -= 1
                        lock.unlock()
                        return false
                    }
                }
                waitingNotificationProducerCount -= 1
            }

            let notification = QueuedTerminalNotification(
                id: UUID(),
                acceptedAt: Date(),
                key: QueuedTerminalNotificationKey(tabId: tabId, surfaceId: surfaceId),
                title: title,
                subtitle: subtitle,
                body: body
            )
            let generation = currentNotificationGeneration
            nextSequence &+= 1
            let sequence = nextSequence
            pending.append(TerminalSocketMutationEntry(
                sequence: sequence,
                mutation: .deliverNotification(notification),
                notificationGeneration: generation,
                performReplaceKey: nil
            ))
            let shouldScheduleDrain = !drainScheduled
            if shouldScheduleDrain {
                drainScheduled = true
            }
            let pendingCount = pending.count - pendingHead
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
    }

    nonisolated func captureNotificationAdmissionToken(tabId: UUID, surfaceId: UUID?) -> TerminalNotificationAdmissionToken {
        lock.lock()
        let registered = ReliableTerminalNotificationAdmission(
            id: UUID(),
            acceptedAt: Date(),
            key: QueuedTerminalNotificationKey(tabId: tabId, surfaceId: surfaceId),
            notificationGeneration: currentNotificationGeneration
        )
        reliableAdmissionsById[registered.id] = registered
        lock.unlock()
        return TerminalNotificationAdmissionToken(id: registered.id)
    }

    /// Called only from the dedicated serial admission queue. At most one
    /// worker waits on the condition while later internal producers remain
    /// suspended behind that worker without occupying cooperative threads.
    nonisolated func enqueueNotificationReliably(
        admissionToken: TerminalNotificationAdmissionToken,
        title: String,
        subtitle: String,
        body: String
    ) -> Bool {
        lock.lock()
        reliablyWaitingNotificationProducerCount += 1
        while pending.count - pendingHead >= Self.maximumPendingMutationCount,
              reliableAdmissionsById[admissionToken.id] != nil {
            lock.wait()
        }
        reliablyWaitingNotificationProducerCount -= 1
        guard let admission = reliableAdmissionsById.removeValue(forKey: admissionToken.id) else {
            lock.unlock()
            return false
        }
        let notification = QueuedTerminalNotification(
            id: admission.id,
            acceptedAt: admission.acceptedAt,
            key: admission.key,
            title: title,
            subtitle: subtitle,
            body: body
        )
        let generation = admission.notificationGeneration
        nextSequence &+= 1
        let sequence = nextSequence
        pending.append(TerminalSocketMutationEntry(
            sequence: sequence,
            mutation: .deliverNotification(notification),
            notificationGeneration: generation,
            performReplaceKey: nil
        ))
        let shouldScheduleDrain = !drainScheduled
        if shouldScheduleDrain { drainScheduled = true }
        lock.unlock()
#if DEBUG
        cmuxDebugLog(
            "notification.queue.enqueueReliable seq=\(sequence) workspace=\(notification.key.tabId.uuidString.prefix(8)) surface=\(notification.key.surfaceId?.uuidString.prefix(8) ?? "nil") generation=\(generation)"
        )
#endif
        if shouldScheduleDrain { scheduleDrain() }
        return true
    }

    nonisolated func enqueueClearAllNotifications() {
        enqueueClear(.clearAllNotifications) { _ in true }
    }
    nonisolated func enqueueClearNotifications(forTabId tabId: UUID) {
        enqueueClear(.clearNotificationsForTab(tabId)) { key in
            key.tabId == tabId
        }
    }

    nonisolated func enqueueClearNotifications(forTabId tabId: UUID, surfaceId: UUID) {
        enqueueClear(
            .clearNotificationsForSurface(tabId, surfaceId)
        ) { key in
            key.tabId == tabId && key.surfaceId == surfaceId
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
        discardPendingNotifications { key, generation in
            key.tabId == tabId && generation <= boundary
        }
    }

    nonisolated func discardPendingNotifications(forTabId tabId: UUID, surfaceId: UUID, through boundary: UInt64) {
        discardPendingNotifications { key, generation in
            key.tabId == tabId
                && key.surfaceId == surfaceId
                && generation <= boundary
        }
    }

    nonisolated func discardPendingNotifications() {
        discardPendingNotifications(advanceGeneration: true) { _, _ in true }
    }

    nonisolated func discardPendingNotifications(forTabId tabId: UUID) {
        discardPendingNotifications { key, _ in
            key.tabId == tabId
        }
    }

    nonisolated func discardPendingNotifications(forTabId tabId: UUID, surfaceId: UUID?) {
        discardPendingNotifications { key, _ in
            key.tabId == tabId && key.surfaceId == surfaceId
        }
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
            pending, fromTabId: fromTabId, toTabId: toTabId, panelIdMap: panelIdMap
        )
        let reliableIds = reliableAdmissionsById.compactMap { id, admission in
            admission.key.tabId == fromTabId ? id : nil
        }
        for id in reliableIds {
            guard var admission = reliableAdmissionsById[id] else { continue }
            admission.key = QueuedTerminalNotificationKey(
                tabId: toTabId,
                surfaceId: admission.key.surfaceId.flatMap { panelIdMap[$0] }
            )
            reliableAdmissionsById[id] = admission
        }
        lock.broadcast()
        lock.unlock()
    }

    private func enqueueClear(
        _ mutation: TerminalSocketMutation,
        dropping shouldDrop: (QueuedTerminalNotificationKey) -> Bool
    ) {
        let shouldScheduleDrain: Bool
        lock.lock()
        reliableAdmissionsById = reliableAdmissionsById.filter { !shouldDrop($0.value.key) }
        compactPendingForMutation()
        pending.removeAll { entry in
            if case .deliverNotification(let notification) = entry.mutation {
                return shouldDrop(notification.key)
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
    nonisolated func notificationQueueStateForTesting() -> (Int, [String], [UInt64]) {
        lock.lock(); defer { lock.unlock() }
        let live = pending[pendingHead...]
        let notifications = live.compactMap { entry -> QueuedTerminalNotification? in
            if case .deliverNotification(let value) = entry.mutation { return value }; return nil
        }
        return (waitingNotificationProducerCount, notifications.map(\.title), live.map(\.sequence))
    }
    nonisolated func reliablyWaitingNotificationProducerCountForTesting() -> Int {
        lock.lock(); defer { lock.unlock() }
        return reliablyWaitingNotificationProducerCount
    }
    nonisolated func notificationIdentityStateForTesting() -> [(UUID, Date, UUID, UUID?, UInt64)] {
        lock.lock(); defer { lock.unlock() }
        return pending[pendingHead...].compactMap { entry in
            guard case .deliverNotification(let notification) = entry.mutation else { return nil }
            return (notification.id, notification.acceptedAt, notification.key.tabId, notification.key.surfaceId, entry.sequence)
        }
    }
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
