public import CmuxMobileRPC
public import Foundation
import Observation

/// Observable, main-actor state for the active Mac's notification feed.
@MainActor
@Observable
public final class MobileNotificationFeedModel {
    /// Feed items sorted newest first.
    public private(set) var items: [MobileNotificationFeedItem] = []
    /// The authoritative or optimistically adjusted unread total.
    public private(set) var unreadCount = 0
    /// Whether a list request is currently in flight.
    public private(set) var isRefreshing = false
    /// Whether at least one authoritative list response has been applied.
    public private(set) var hasLoaded = false
    private var needsFollowUpRefresh = false

    /// Creates empty notification-feed state.
    public init() {}

    /// Applies an authoritative list response and restores newest-first ordering.
    /// - Parameter response: The decoded Mac response.
    public func applyList(_ response: MobileNotificationListResponse) {
        items = response.items.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.createdAt > rhs.createdAt
        }
        unreadCount = max(0, response.unreadCount)
        hasLoaded = true
    }

    /// Marks matching items read and adjusts the unread total by real transitions.
    /// - Parameter ids: Notification identifiers to mark read.
    public func markRead(_ ids: some Sequence<UUID>) {
        let target = Set(ids)
        guard !target.isEmpty else { return }
        var transitions = 0
        items = items.map { item in
            guard target.contains(item.id), !item.isRead else { return item }
            transitions += 1
            return item.settingRead(true)
        }
        unreadCount = max(0, unreadCount - transitions)
    }

    /// Marks one matching item unread and adjusts the unread total once.
    /// - Parameter id: The notification identifier to mark unread.
    public func markUnread(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isRead else { return }
        items[index] = items[index].settingRead(false)
        unreadCount += 1
    }

    /// Removes matching items and subtracts any removed unread items.
    /// - Parameter ids: Notification identifiers to remove.
    public func remove(_ ids: some Sequence<UUID>) {
        let target = Set(ids)
        guard !target.isEmpty else { return }
        let removedUnread = items.lazy.filter { target.contains($0.id) && !$0.isRead }.count
        items.removeAll { target.contains($0.id) }
        unreadCount = max(0, unreadCount - removedUnread)
    }

    /// Replaces the unread total from an authoritative event lane.
    /// - Parameter count: The Mac-reported unread total.
    public func applyUnreadCount(_ count: Int) {
        unreadCount = max(0, count)
    }

    /// Claims the single refresh slot, or records that one follow-up is needed.
    /// - Returns: `true` when the caller should start the request.
    public func beginRefresh() -> Bool {
        guard !isRefreshing else {
            needsFollowUpRefresh = true
            return false
        }
        isRefreshing = true
        return true
    }

    /// Finishes a refresh and reports whether events requested one coalesced follow-up.
    /// - Returns: `true` when another request should run immediately.
    public func finishRefresh() -> Bool {
        isRefreshing = false
        defer { needsFollowUpRefresh = false }
        return needsFollowUpRefresh
    }

    /// Splits unread identifiers into wire-safe batches.
    /// - Parameter maximumBatchSize: Maximum identifiers per batch.
    /// - Returns: Newest-first unread identifiers chunked to the requested cap.
    public func unreadIDBatches(maximumBatchSize: Int = 256) -> [[UUID]] {
        guard maximumBatchSize > 0 else { return [] }
        let ids = items.lazy.filter { !$0.isRead }.map(\.id)
        var batches: [[UUID]] = []
        var batch: [UUID] = []
        batch.reserveCapacity(maximumBatchSize)
        for id in ids {
            batch.append(id)
            if batch.count == maximumBatchSize {
                batches.append(batch)
                batch = []
                batch.reserveCapacity(maximumBatchSize)
            }
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }
}
