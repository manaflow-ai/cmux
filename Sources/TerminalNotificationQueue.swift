import Foundation

enum ReliableTerminalNotificationEnqueueResult: Sendable, Equatable {
    case accepted
    case saturated
    case cancelled
}

private enum TerminalNotificationClearTarget {
    case all
    case workspace(UUID)
    case surface(tabId: UUID, surfaceId: UUID)
}

final class TerminalMutationBus: @unchecked Sendable {
    static let shared = TerminalMutationBus()
    static let maximumPendingMutationCount = 256
    static let maximumWaitingNotificationProducerCount = 16
    static let notificationCapacityWaitTimeout: TimeInterval = 1
    static let maximumNotificationLiveOwnerRouteCount = 2_048

    private static let reliableAdmissionQueue = DispatchQueue(
        label: "com.cmux.agent-notification-reliable-admission",
        qos: .utility
    )
    private static let reliableSubmissionLock = NSLock()
    let lock = NSCondition()
    var pending: [TerminalSocketMutationEntry] = []
    var pendingHead = 0
    private var drainScheduled = false
    private var nextSequence: UInt64 = 0
    var currentNotificationGeneration: UInt64 = 0
    private var waitingNotificationProducerCount = 0
    var reliableAdmissionsById: [UUID: ReliableTerminalNotificationAdmission] = [:]
    static let maximumNotificationReplacementRouteCount = 256
    var notificationReplacementRoutesByTabId: [UUID: TerminalNotificationReplacementRoute] = [:]
    var notificationReplacementRouteOrder: [UUID] = []
    var notificationLiveOwnerTabIdBySurfaceId: [UUID: UUID] = [:]
    var notificationLiveOwnerSurfaceOrder: [UUID] = []
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

            let routedKey = notificationKeyFollowingReplacementRoutes(
                QueuedTerminalNotificationKey(tabId: tabId, surfaceId: surfaceId)
            )
            let notification = QueuedTerminalNotification(
                id: UUID(),
                acceptedAt: Date(),
                key: routedKey,
                allowWorkspaceFallbackForValidatedSurface: false,
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

    /// Registers acceptance and submits capacity waiting through the bus-owned
    /// serial worker, so callers cannot bypass the single-waiter invariant.
    nonisolated func enqueueNotificationReliably(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String,
        allowWorkspaceFallbackForValidatedSurface: Bool = false
    ) async -> ReliableTerminalNotificationEnqueueResult {
        await withCheckedContinuation { continuation in
            Self.reliableSubmissionLock.lock()
            guard let admissionToken = captureNotificationAdmissionToken(
                tabId: tabId,
                surfaceId: surfaceId,
                allowWorkspaceFallbackForValidatedSurface: allowWorkspaceFallbackForValidatedSurface
            ) else {
                Self.reliableSubmissionLock.unlock()
                continuation.resume(returning: .saturated)
                return
            }
            Self.reliableAdmissionQueue.async { [self] in
                continuation.resume(returning: enqueueCapturedNotificationReliably(
                    admissionToken: admissionToken,
                    title: title,
                    subtitle: subtitle,
                    body: body
                ))
            }
            Self.reliableSubmissionLock.unlock()
        }
    }

    private nonisolated func captureNotificationAdmissionToken(
        tabId: UUID,
        surfaceId: UUID?,
        allowWorkspaceFallbackForValidatedSurface: Bool
    ) -> TerminalNotificationAdmissionToken? {
        lock.lock()
        guard reliableAdmissionsById.count < Self.maximumWaitingNotificationProducerCount else {
            lock.unlock()
            return nil
        }
        let routedKey = notificationKeyFollowingReplacementRoutes(
            QueuedTerminalNotificationKey(tabId: tabId, surfaceId: surfaceId)
        )
        let registered = ReliableTerminalNotificationAdmission(
            id: UUID(),
            acceptedAt: Date(),
            key: routedKey,
            allowWorkspaceFallbackForValidatedSurface: allowWorkspaceFallbackForValidatedSurface,
            notificationGeneration: currentNotificationGeneration
        )
        reliableAdmissionsById[registered.id] = registered
        lock.unlock()
        return TerminalNotificationAdmissionToken(id: registered.id)
    }

    /// Called only from the bus-owned serial admission queue. At most one
    /// worker waits on the condition while later internal producers remain
    /// suspended behind that worker without occupying cooperative threads.
    private nonisolated func enqueueCapturedNotificationReliably(
        admissionToken: TerminalNotificationAdmissionToken,
        title: String,
        subtitle: String,
        body: String
    ) -> ReliableTerminalNotificationEnqueueResult {
        lock.lock()
        reliablyWaitingNotificationProducerCount += 1
        while pending.count - pendingHead >= Self.maximumPendingMutationCount,
              reliableAdmissionsById[admissionToken.id] != nil {
            lock.wait()
        }
        reliablyWaitingNotificationProducerCount -= 1
        guard let admission = reliableAdmissionsById.removeValue(forKey: admissionToken.id) else {
            lock.unlock()
            return .cancelled
        }
        let notification = QueuedTerminalNotification(
            id: admission.id,
            acceptedAt: admission.acceptedAt,
            key: admission.key,
            allowWorkspaceFallbackForValidatedSurface: admission.allowWorkspaceFallbackForValidatedSurface,
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
        return .accepted
    }

    nonisolated func enqueueClearAllNotifications() {
        enqueueClear(.all)
    }
    nonisolated func enqueueClearNotifications(forTabId tabId: UUID) {
        enqueueClear(.workspace(tabId))
    }

    nonisolated func enqueueClearNotifications(forTabId tabId: UUID, surfaceId: UUID) {
        enqueueClear(.surface(tabId: tabId, surfaceId: surfaceId))
    }

    nonisolated func enqueueMainActorMutation(_ mutation: @escaping @MainActor () -> Void) {
        enqueueBarrierMutation(.perform(mutation))
    }

    private func enqueueClear(_ target: TerminalNotificationClearTarget) {
        let shouldScheduleDrain: Bool
        lock.lock()
        let routedTarget: TerminalNotificationClearTarget
        switch target {
        case .all:
            routedTarget = .all
        case .workspace(let tabId):
            let key = notificationKeyFollowingReplacementRoutes(
                QueuedTerminalNotificationKey(tabId: tabId, surfaceId: nil)
            )
            routedTarget = .workspace(key.tabId)
        case .surface(let tabId, let surfaceId):
            let key = notificationKeyFollowingReplacementRoutes(
                QueuedTerminalNotificationKey(tabId: tabId, surfaceId: surfaceId)
            )
            routedTarget = .surface(tabId: key.tabId, surfaceId: key.surfaceId ?? surfaceId)
        }
        func shouldDropPending(_ key: QueuedTerminalNotificationKey) -> Bool {
            switch routedTarget {
            case .all:
                return true
            case .workspace(let tabId):
                // Surface-addressed entries may have moved since enqueue. The
                // live-owner route is authoritative when present; unresolved
                // entries remain before the barrier for main-actor resolution.
                return key.tabId == tabId && key.surfaceId == nil
            case .surface(_, let surfaceId):
                return key.surfaceId == surfaceId
            }
        }
        func shouldDropReliableAdmission(_ key: QueuedTerminalNotificationKey) -> Bool {
            switch routedTarget {
            case .all:
                return true
            case .workspace(let tabId):
                return key.tabId == tabId
            case .surface(_, let surfaceId):
                return key.surfaceId == surfaceId
            }
        }
        let boundary = currentNotificationGeneration
        currentNotificationGeneration &+= 1
        reliableAdmissionsById = reliableAdmissionsById.filter { !shouldDropReliableAdmission($0.value.key) }
        compactPendingForMutation()
        pending.removeAll { entry in
            if case .deliverNotification(let notification) = entry.mutation {
                return shouldDropPending(notification.key)
            }
            return false
        }
        nextSequence &+= 1
        let mutation: TerminalSocketMutation
        switch routedTarget {
        case .all:
            mutation = .clearAllNotifications(through: boundary)
        case .workspace(let tabId):
            mutation = .clearNotificationsForTab(tabId, through: boundary)
        case .surface(let tabId, let surfaceId):
            mutation = .clearNotificationsForSurface(tabId, surfaceId, through: boundary)
        }
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
    func compactPendingForMutation() {
        guard pendingHead > 0 else { return }
        pending.removeFirst(pendingHead)
        pendingHead = 0
    }

}
