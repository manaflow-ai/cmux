import Foundation

final class FeedTransientAttentionStore {
    struct Key: Hashable {
        let source: String
        let sessionId: String
        let requestId: String
    }

    struct Entry {
        let target: FeedCoordinator.AttentionTarget
        let notificationCorrelationKey: String
    }

    @MainActor private var entries: [Key: Entry] = [:]

    @MainActor
    func entry(for key: Key) -> Entry? {
        entries[key]
    }

    @MainActor
    func insert(_ entry: Entry, for key: Key) {
        entries[key] = entry
    }

    @MainActor
    func removeValue(for key: Key) -> Entry? {
        entries.removeValue(forKey: key)
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
        transientAttentionStore.insert(
            FeedTransientAttentionStore.Entry(
                target: target,
                notificationCorrelationKey: correlationKey
            ),
            for: key
        )
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
        concludeBlockingDecisionAttention(entry.target)
        TerminalMutationBus.shared.enqueueMainActorMutation {
            TerminalNotificationStore.shared.clearNotifications(
                correlationKey: entry.notificationCorrelationKey
            )
        }
        return true
    }
}
