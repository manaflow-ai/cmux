import CmuxRemoteSession
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
    case clearAllNotifications(through: UInt64)
    case clearNotificationsForTab(UUID, through: UInt64)
    case clearNotificationsForSurface(UUID, UUID, through: UInt64)
    case perform(@MainActor () -> Void)
}

fileprivate struct TerminalSocketMutationEntry {
    let sequence: UInt64
    let mutation: TerminalSocketMutation
    let notificationGeneration: UInt64?
    let notificationCoalescingKey: TerminalNotificationCoalescingKey?
    let performReplaceKey: TerminalMutationReplaceKey?
}

/// Identity for last-write-wins `.perform` mutations: a fresh enqueue removes
/// the pending same-key entry, bounding `pending` at one entry per key even
/// while the main actor is blocked and cannot drain.
struct TerminalMutationReplaceKey: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case shellActivity, gitBranch, directory
        case portsKick(PortScanKickReason)
    }

    let tabId: UUID
    let surfaceId: UUID
    let kind: Kind
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
        body: String,
        coalesces: Bool = true
    ) {
        enqueueNotification(QueuedTerminalNotification(
            key: QueuedTerminalNotificationKey(tabId: tabId, surfaceId: surfaceId),
            title: title,
            subtitle: subtitle,
            body: body
        ), coalesces: coalesces)
    }

    nonisolated func enqueueClearAllNotifications() {
        enqueueClear({ .clearAllNotifications(through: $0) }) { _ in true }
    }

    nonisolated func enqueueClearNotifications(forTabId tabId: UUID) {
        // Surface-addressed entries may have moved since enqueue. Keep them
        // ahead of the barrier so delivery can resolve their live owner first.
        enqueueClear({ .clearNotificationsForTab(tabId, through: $0) }) { notification in
            notification.key.tabId == tabId && notification.key.surfaceId == nil
        }
    }

    nonisolated func enqueueClearNotifications(forTabId tabId: UUID, surfaceId: UUID) {
        // Canonical surface identity: a stale-keyed entry would retarget here at drain.
        enqueueClear({ .clearNotificationsForSurface(tabId, surfaceId, through: $0) }) { notification in
            notification.key.surfaceId == surfaceId
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

    nonisolated func notificationGenerationSnapshot() -> UInt64 { lock.withLock { currentNotificationGeneration } }

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

    /// Exact enqueue-key discard. Use for source-scoped operations like
    /// `rebindSurfaceNotifications`, where a surface-wide discard could drop a
    /// newer entry legitimately queued under the destination key mid-move.
    nonisolated func discardPendingNotifications(forTabId tabId: UUID, surfaceId: UUID?) {
        discardPendingNotifications { notification, _ in
            notification.key.tabId == tabId && notification.key.surfaceId == surfaceId
        }
    }

    /// Canonical-identity discard for clears and supersedes: pending entries
    /// are keyed by their enqueue-time (claimed) workspace but DELIVER to the
    /// surface's live owner (#7939), so a clear that matched only the claimed
    /// key would let a stale-keyed entry resurrect the notification at drain.
    nonisolated func discardPendingNotifications(forSurfaceId surfaceId: UUID) {
        discardPendingNotifications { notification, _ in
            notification.key.surfaceId == surfaceId
        }
    }

    /// Clear-scoped discard: canonical surface identity when surface-scoped;
    /// live destination workspace when workspace-scoped.
    @MainActor
    func discardPendingNotificationsForClear(tabId: UUID, surfaceId: UUID?) {
        if let surfaceId { discardPendingNotifications(forSurfaceId: surfaceId) }
        else { discardPendingNotificationsResolvingLiveOwner(forTabId: tabId) }
    }

    /// Phase 1 of the live-owner workspace clear (see
    /// `discardPendingNotificationsResolvingLiveOwner(forTabId:)`): the
    /// pending notification addresses, identified by their exact sequence.
    nonisolated func pendingNotificationAddressesSnapshot() -> [(sequence: UInt64, tabId: UUID, surfaceId: UUID?)] {
        lock.lock()
        defer { lock.unlock() }
        return pending.compactMap { entry in
            guard case .deliverNotification(let notification) = entry.mutation else { return nil }
            return (entry.sequence, notification.key.tabId, notification.key.surfaceId)
        }
    }

    /// Phase 2: discard exactly the snapshotted entries; anything enqueued
    /// after the snapshot keeps its place.
    nonisolated func discardPendingNotifications(sequences: Set<UInt64>) {
        guard !sequences.isEmpty else { return }
        lock.lock()
        pending.removeAll { entry in
            guard case .deliverNotification = entry.mutation else { return false }
            return sequences.contains(entry.sequence)
        }
        lock.unlock()
    }

    private func enqueueNotification(_ notification: QueuedTerminalNotification, coalesces: Bool) {
        let shouldScheduleDrain: Bool
        let removedCount: Int
        let pendingCount: Int
        let sequence: UInt64
        let generation: UInt64
        lock.lock()
        generation = currentNotificationGeneration
        let coalescingKey = coalesces
            ? TerminalNotificationCoalescingKey(
                generation: generation,
                notificationKey: notification.key
            )
            : nil
        let beforeCount = pending.count
        if let coalescingKey {
            pending.removeAll { entry in
                entry.notificationCoalescingKey == coalescingKey
            }
        }
        removedCount = beforeCount - pending.count
        nextSequence &+= 1
        sequence = nextSequence
        pending.append(TerminalSocketMutationEntry(
            sequence: sequence,
            mutation: .deliverNotification(notification),
            notificationGeneration: generation,
            notificationCoalescingKey: coalescingKey,
            performReplaceKey: nil
        ))
        shouldScheduleDrain = !drainScheduled
        if shouldScheduleDrain {
            drainScheduled = true
        }
        pendingCount = pending.count
        lock.unlock()

#if DEBUG
        cmuxDebugLog(
            "notification.queue.enqueue seq=\(sequence) workspace=\(notification.key.tabId.uuidString.prefix(8)) surface=\(notification.key.surfaceId?.uuidString.prefix(8) ?? "nil") coalesces=\(coalesces ? 1 : 0) removed=\(removedCount) pending=\(pendingCount) generation=\(generation) titleLen=\(notification.title.count) subtitleLen=\(notification.subtitle.count) bodyLen=\(notification.body.count)"
        )
#endif

        guard shouldScheduleDrain else { return }
        scheduleDrain()
    }

    private func enqueueClear(
        _ mutation: (UInt64) -> TerminalSocketMutation,
        dropping shouldDrop: (QueuedTerminalNotification) -> Bool
    ) {
        let shouldScheduleDrain: Bool
        lock.lock()
        let boundary = currentNotificationGeneration
        currentNotificationGeneration &+= 1
        pending.removeAll { entry in
            if case .deliverNotification(let notification) = entry.mutation {
                return shouldDrop(notification)
            }
            return false
        }
        nextSequence &+= 1
        pending.append(TerminalSocketMutationEntry(
            sequence: nextSequence,
            mutation: mutation(boundary),
            notificationGeneration: nil,
            notificationCoalescingKey: nil,
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

    private func enqueueBarrierMutation(_ mutation: TerminalSocketMutation) {
        let shouldScheduleDrain: Bool
        lock.lock()
        nextSequence &+= 1
        pending.append(TerminalSocketMutationEntry(
            sequence: nextSequence,
            mutation: mutation,
            notificationGeneration: nil,
            notificationCoalescingKey: nil,
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
    /// applies at its new enqueue position (the notification coalescing
    /// semantics above, for `.perform` mutations).
    nonisolated func enqueueReplacingMainActorMutation(
        replaceKey: TerminalMutationReplaceKey,
        _ mutation: @escaping @MainActor () -> Void
    ) {
        let shouldScheduleDrain: Bool
        lock.lock()
        pending.removeAll { $0.performReplaceKey == replaceKey }
        nextSequence &+= 1
        pending.append(TerminalSocketMutationEntry(
            sequence: nextSequence,
            mutation: .perform(mutation),
            notificationGeneration: nil,
            notificationCoalescingKey: nil,
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
        let remaining = pending.count
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
#if DEBUG
                cmuxDebugLog(
                    "notification.queue.perform seq=\(entry.sequence) workspace=\(notification.key.tabId.uuidString.prefix(8)) surface=\(notification.key.surfaceId?.uuidString.prefix(8) ?? "nil") titleLen=\(notification.title.count) subtitleLen=\(notification.subtitle.count) bodyLen=\(notification.body.count)"
                )
#endif
                TerminalNotificationStore.shared.deliverQueuedNotification(
                    claimedTabId: notification.key.tabId,
                    surfaceId: notification.key.surfaceId,
                    title: notification.title,
                    subtitle: notification.subtitle,
                    body: notification.body,
                    notificationGeneration: entry.notificationGeneration ?? 0
                )
            case .clearAllNotifications(let boundary):
                TerminalNotificationStore.shared.clearAll(discardQueuedNotifications: false, throughNotificationGeneration: boundary)
            case .clearNotificationsForTab(let tabId, let boundary):
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: tabId,
                    discardQueuedNotifications: false,
                    throughNotificationGeneration: boundary
                )
            case .clearNotificationsForSurface(let tabId, let surfaceId, let boundary):
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: tabId,
                    surfaceId: surfaceId,
                    discardQueuedNotifications: false,
                    throughNotificationGeneration: boundary
                )
            case .perform(let mutation):
                mutation()
            }
        }
    }
}

extension TerminalNotificationStore {
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
