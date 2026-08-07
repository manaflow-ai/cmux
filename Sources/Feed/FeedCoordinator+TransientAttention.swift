import CMUXAgentLaunch
import Foundation

@MainActor
final class FeedTransientAttentionStore {
    nonisolated static let defaultMaximumEntryCount = 256
    nonisolated static let defaultRetentionDuration: Duration = .seconds(24 * 60 * 60)

    struct Key: Hashable, Sendable {
        let source: String
        let sessionId: String
        let requestId: String
    }

    struct Entry: Sendable {
        let target: FeedCoordinator.AttentionTarget
        let notificationCorrelationKey: String
        let ownerPID: Int?

        init(
            target: FeedCoordinator.AttentionTarget,
            notificationCorrelationKey: String,
            ownerPID: Int? = nil
        ) {
            self.target = target
            self.notificationCorrelationKey = notificationCorrelationKey
            self.ownerPID = ownerPID
        }
    }

    private struct StoredEntry {
        let entry: Entry
        let insertionOrder: UInt64
        let expirationTask: Task<Void, Never>
    }

    private let clock: any Clock<Duration>
    private let maximumEntryCount: Int
    private let retentionDuration: Duration
    private let expirationHandler: @MainActor @Sendable (Entry) -> Void
    private var entries: [Key: StoredEntry] = [:]
    private var nextInsertionOrder: UInt64 = 0

    init(
        clock: any Clock<Duration> = ContinuousClock(),
        maximumEntryCount: Int = defaultMaximumEntryCount,
        retentionDuration: Duration = defaultRetentionDuration,
        expirationHandler: @escaping @MainActor @Sendable (Entry) -> Void = { _ in }
    ) {
        self.clock = clock
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.retentionDuration = max(.zero, retentionDuration)
        self.expirationHandler = expirationHandler
    }

    func entry(for key: Key) -> Entry? {
        entries[key]?.entry
    }

    /// Inserts one request and returns any oldest entries evicted to preserve
    /// the hard registry bound. Duplicate request identities remain idempotent.
    @discardableResult
    func insert(_ entry: Entry, for key: Key) -> [Entry] {
        guard entries[key] == nil else { return [] }

        var evicted: [Entry] = []
        while entries.count >= maximumEntryCount,
              let oldestKey = entries.min(by: {
                  $0.value.insertionOrder < $1.value.insertionOrder
              })?.key,
              let oldest = removeValue(for: oldestKey) {
            evicted.append(oldest)
        }

        let clock = clock
        let retentionDuration = retentionDuration
        let expirationTask = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(for: retentionDuration, tolerance: nil)
            } catch {
                return
            }
            self?.expireValue(for: key)
        }
        entries[key] = StoredEntry(
            entry: entry,
            insertionOrder: nextInsertionOrder,
            expirationTask: expirationTask
        )
        nextInsertionOrder &+= 1
        return evicted
    }

    func removeValue(for key: Key) -> Entry? {
        guard let stored = entries.removeValue(forKey: key) else { return nil }
        stored.expirationTask.cancel()
        return stored.entry
    }

    func removeValues(ownerPID: Int) -> [Entry] {
        removeValues { $0.ownerPID == ownerPID }
    }

    func removeValues(workspaceId: UUID) -> [Entry] {
        removeValues { $0.target.workspaceId == workspaceId }
    }

    private func expireValue(for key: Key) {
        guard let entry = removeValue(for: key) else { return }
        expirationHandler(entry)
    }

    private func removeValues(
        where predicate: (Entry) -> Bool
    ) -> [Entry] {
        let matchingKeys = entries
            .filter { predicate($0.value.entry) }
            .sorted { $0.value.insertionOrder < $1.value.insertionOrder }
            .map(\.key)
        return matchingKeys.compactMap(removeValue(for:))
    }
}

extension FeedCoordinator {
    /// Acquires attention for a blocker that intentionally does not create a
    /// durable Feed item (Claude's bypass-permissions question/plan fallback).
    /// The request is deduplicated by agent/session/tool identity, while the
    /// visible state uses the same per-target refcount as Feed decisions.
    @MainActor
    func beginTransientBlockingAttention(
        source: String,
        sessionId: String,
        requestId: String,
        workspaceId: UUID,
        surfaceId: UUID,
        ownerPID: Int?,
        title: String,
        subtitle: String,
        body: String
    ) -> Bool {
        let key = FeedTransientAttentionStore.Key(
            source: source,
            sessionId: sessionId,
            requestId: requestId
        )
        if transientAttentionStore.entry(for: key) != nil {
            return true
        }

        let event = WorkstreamEvent(
            sessionId: "\(source)-\(sessionId)",
            hookEventName: .askUserQuestion,
            source: source,
            workspaceId: workspaceId.uuidString,
            surfaceId: surfaceId.uuidString,
            requestId: requestId
        )
        guard let target = surfaceBlockingDecisionAttention(
            event: event,
            resolved: (workspaceId: workspaceId, surfaceId: surfaceId)
        ) else {
            return false
        }

        let correlationKey = "transient-agent-attention:\(UUID().uuidString)"
        let evicted = transientAttentionStore.insert(
            FeedTransientAttentionStore.Entry(
                target: target,
                notificationCorrelationKey: correlationKey,
                ownerPID: ownerPID
            ),
            for: key
        )
        for entry in evicted {
            concludeTransientBlockingAttention(entry)
        }
        if let ownerPID, ownerPID > 0 {
            armPidWatcher(ppid: ownerPID)
        }
        _ = AgentNotificationDelivery().enqueue(
            workspaceID: workspaceId,
            surfaceID: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            category: .needsPermission,
            pending: false,
            coalesces: false,
            correlationKey: correlationKey
        )
        return true
    }

    /// Releases exactly one transient request. A missing or duplicate release
    /// is a no-op, and Feed-owned attention on the same pane remains refcounted.
    @MainActor
    func endTransientBlockingAttention(
        source: String,
        sessionId: String,
        requestId: String
    ) -> Bool {
        let key = FeedTransientAttentionStore.Key(
            source: source,
            sessionId: sessionId,
            requestId: requestId
        )
        guard let entry = transientAttentionStore.removeValue(for: key) else {
            return false
        }
        concludeTransientBlockingAttention(entry)
        return true
    }

    /// Releases every transient request owned by an exited agent process.
    /// Feed already uses a kqueue-backed watcher for durable decisions, so
    /// transient blockers share that same process-lifecycle authority.
    @MainActor
    func endTransientBlockingAttention(ownerPID: Int) {
        for entry in transientAttentionStore.removeValues(ownerPID: ownerPID) {
            concludeTransientBlockingAttention(entry)
        }
    }

    /// Releases requests whose workspace was explicitly closed, balancing
    /// attention even when the hook process or its terminal callback vanished.
    @MainActor
    func endTransientBlockingAttention(workspaceId: UUID) {
        for entry in transientAttentionStore.removeValues(workspaceId: workspaceId) {
            concludeTransientBlockingAttention(entry)
        }
    }

    @MainActor
    func concludeTransientBlockingAttention(
        _ entry: FeedTransientAttentionStore.Entry
    ) {
        concludeBlockingDecisionAttention(entry.target)
        TerminalMutationBus.shared.enqueueMainActorMutation {
            TerminalNotificationStore.shared.clearNotifications(
                correlationKey: entry.notificationCorrelationKey
            )
        }
    }
}
