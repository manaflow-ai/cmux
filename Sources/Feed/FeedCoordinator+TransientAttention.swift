import CMUXAgentLaunch
import Foundation

@MainActor
final class FeedTransientAttentionStore {
    nonisolated static let defaultMaximumEntryCount = 256

    struct Key: Hashable, Sendable {
        let source: String
        let sessionId: String
        let requestId: String
    }

    struct Entry: Sendable {
        let target: FeedCoordinator.AttentionTarget
        let notificationCorrelationKey: String
        let ownerProcessIdentity: AgentPIDProcessIdentity

        init(
            target: FeedCoordinator.AttentionTarget,
            notificationCorrelationKey: String,
            ownerProcessIdentity: AgentPIDProcessIdentity
        ) {
            self.target = target
            self.notificationCorrelationKey = notificationCorrelationKey
            self.ownerProcessIdentity = ownerProcessIdentity
        }
    }

    private struct StoredEntry {
        let entry: Entry
        let insertionOrder: UInt64
    }

    private let maximumEntryCount: Int
    private var entries: [Key: StoredEntry] = [:]
    private var nextInsertionOrder: UInt64 = 0

    init(
        maximumEntryCount: Int = defaultMaximumEntryCount
    ) {
        self.maximumEntryCount = max(1, maximumEntryCount)
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

        entries[key] = StoredEntry(
            entry: entry,
            insertionOrder: nextInsertionOrder
        )
        nextInsertionOrder &+= 1
        return evicted
    }

    func removeValue(for key: Key) -> Entry? {
        entries.removeValue(forKey: key)?.entry
    }

    func removeValues(ownerProcessIdentity: AgentPIDProcessIdentity) -> [Entry] {
        removeValues { $0.ownerProcessIdentity == ownerProcessIdentity }
    }

    func removeValues(workspaceId: UUID) -> [Entry] {
        removeValues { $0.target.workspaceId == workspaceId }
    }

    func contains(ownerProcessIdentity: AgentPIDProcessIdentity) -> Bool {
        entries.values.contains {
            $0.entry.ownerProcessIdentity == ownerProcessIdentity
        }
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
        ownerProcessIdentity: AgentPIDProcessIdentity,
        title: String,
        subtitle: String,
        body: String
    ) -> Bool {
        let key = FeedTransientAttentionStore.Key(
            source: source,
            sessionId: sessionId,
            requestId: requestId
        )
        guard AgentPIDProcessIdentity(pid: ownerProcessIdentity.pid) == ownerProcessIdentity else {
            return false
        }
        if let existing = transientAttentionStore.entry(for: key) {
            return existing.ownerProcessIdentity == ownerProcessIdentity
        }

        guard let liveTarget = AppDelegate.shared?.agentNotificationDeliveryTarget(
            claimedTabId: workspaceId,
            surfaceId: surfaceId
        ), let liveSurfaceId = liveTarget.surfaceId else { return false }
        let liveWorkspaceId = liveTarget.tabId

        let event = WorkstreamEvent(
            sessionId: "\(source)-\(sessionId)",
            hookEventName: .askUserQuestion,
            source: source,
            workspaceId: liveWorkspaceId.uuidString,
            surfaceId: liveSurfaceId.uuidString,
            requestId: requestId
        )
        guard let target = surfaceBlockingDecisionAttention(
            event: event,
            resolved: (workspaceId: liveWorkspaceId, surfaceId: liveSurfaceId)
        ) else {
            return false
        }

        let correlationKey = "transient-agent-attention:\(UUID().uuidString)"
        let evicted = transientAttentionStore.insert(
            FeedTransientAttentionStore.Entry(
                target: target,
                notificationCorrelationKey: correlationKey,
                ownerProcessIdentity: ownerProcessIdentity
            ),
            for: key
        )
        concludeTransientBlockingAttention(evicted)
        guard armTransientAttentionProcessWatcher(ownerProcessIdentity) else {
            if let entry = transientAttentionStore.removeValue(for: key) {
                concludeTransientBlockingAttention([entry])
            }
            return false
        }
        _ = AgentNotificationDelivery().enqueue(
            workspaceID: liveWorkspaceId,
            surfaceID: liveSurfaceId,
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
        concludeTransientBlockingAttention([entry])
        return true
    }

    /// Releases every transient request owned by an exited agent process.
    /// Feed already uses a kqueue-backed watcher for durable decisions, so
    /// transient blockers share that same process-lifecycle authority.
    @MainActor
    func endTransientBlockingAttention(
        ownerProcessIdentity: AgentPIDProcessIdentity
    ) {
        concludeTransientBlockingAttention(
            transientAttentionStore.removeValues(
                ownerProcessIdentity: ownerProcessIdentity
            )
        )
    }

    /// Releases requests whose workspace was explicitly closed, balancing
    /// attention even when the hook process or its terminal callback vanished.
    @MainActor
    func endTransientBlockingAttention(workspaceId: UUID) {
        concludeTransientBlockingAttention(
            transientAttentionStore.removeValues(workspaceId: workspaceId)
        )
    }

    @MainActor
    func concludeTransientBlockingAttention(
        _ entries: [FeedTransientAttentionStore.Entry]
    ) {
        guard !entries.isEmpty else { return }
        for entry in entries {
            concludeBlockingDecisionAttention(entry.target)
        }
        let correlationKeys = Set(entries.map(\.notificationCorrelationKey))
        TerminalMutationBus.shared.enqueueMainActorMutation {
            TerminalNotificationStore.shared.clearNotifications(
                correlationKeys: correlationKeys
            )
        }
        for identity in Set(entries.map(\.ownerProcessIdentity)) {
            disarmTransientAttentionProcessWatcherIfUnused(identity)
        }
    }

    /// Watches one exact process generation. Numeric PID reuse cannot release
    /// attention owned by a later process because both the registry and watcher
    /// are keyed by the captured birth timestamp.
    @MainActor
    private func armTransientAttentionProcessWatcher(
        _ identity: AgentPIDProcessIdentity
    ) -> Bool {
        guard AgentPIDProcessIdentity(pid: identity.pid) == identity else { return false }
        if transientAttentionProcessWatchers[identity] != nil { return true }

        let source = DispatchSource.makeProcessSource(
            identifier: identity.pid,
            eventMask: .exit,
            queue: pidWatcherQueue
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.endTransientBlockingAttention(
                    ownerProcessIdentity: identity
                )
            }
        }
        transientAttentionProcessWatchers[identity] = source
        source.resume()

        guard AgentPIDProcessIdentity(pid: identity.pid) == identity else {
            source.cancel()
            transientAttentionProcessWatchers.removeValue(forKey: identity)
            return false
        }
        return true
    }

    @MainActor
    private func disarmTransientAttentionProcessWatcherIfUnused(
        _ identity: AgentPIDProcessIdentity
    ) {
        guard !transientAttentionStore.contains(ownerProcessIdentity: identity),
              let source = transientAttentionProcessWatchers.removeValue(forKey: identity) else {
            return
        }
        source.cancel()
    }
}
