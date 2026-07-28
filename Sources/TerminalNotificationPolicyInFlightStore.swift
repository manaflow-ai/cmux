import Foundation

/// Tracks notification-policy evaluations across their asynchronous hook
/// boundary so a clear can invalidate work that has left the mutation queue
/// but has not yet applied to the notification store.
@MainActor
final class TerminalNotificationPolicyInFlightStore {
    private struct Entry {
        let request: TerminalNotificationPolicyRequest
        let generation: UInt64
        let deliveryIdentity: TerminalNotificationPolicyDeliveryIdentity
        var onDiscard: @MainActor @Sendable () -> Void
        var indexedTabId: UUID
        var task: Task<Void, Never>?
        var completion: (@MainActor () -> Void)?
    }
    private let maximumRequestCount = 1_024
    private var requests: [UUID: Entry] = [:]
    private var evictionOrder: [UUID] = []
    private var evictionOrderOffset = 0
    private var requestIDsByDeliveryIdentity: [TerminalNotificationPolicyDeliveryIdentity: [UUID]] = [:]
    private var requestOffsetByDeliveryIdentity: [TerminalNotificationPolicyDeliveryIdentity: Int] = [:]
    private var requestCountByTabId: [UUID: Int] = [:]
    private var requestCountByTabSurface: [UUID: [UUID?: Int]] = [:]

    func register(
        _ request: TerminalNotificationPolicyRequest,
        generation: UInt64,
        onDiscard: @escaping @MainActor @Sendable () -> Void
    ) -> UUID {
        compactEvictionOrderIfNeeded()
        var identitiesToDrain = Set<TerminalNotificationPolicyDeliveryIdentity>()
        while requests.count >= maximumRequestCount, evictionOrderOffset < evictionOrder.count {
            let id = evictionOrder[evictionOrderOffset]
            evictionOrderOffset += 1
            if let identity = discardRequest(id) {
                identitiesToDrain.insert(identity)
            }
        }
        identitiesToDrain.forEach(drainCompletedRequests)
        let id = UUID()
        let deliveryIdentity = TerminalNotificationPolicyDeliveryIdentity(request: request)
        requests[id] = Entry(
            request: request,
            generation: generation,
            deliveryIdentity: deliveryIdentity,
            onDiscard: onDiscard,
            indexedTabId: request.tabId,
            task: nil,
            completion: nil
        )
        incrementIndexes(for: request, tabId: request.tabId)
        evictionOrder.append(id)
        requestIDsByDeliveryIdentity[deliveryIdentity, default: []].append(id)
        return id
    }

    func attach(task: Task<Void, Never>, to id: UUID) {
        guard var entry = requests[id] else { task.cancel(); return }
        entry.task = task
        requests[id] = entry
    }

    /// Transfers cleanup ownership when an early reservation reaches policy evaluation.
    func updateOnDiscard(
        _ onDiscard: @escaping @MainActor @Sendable () -> Void,
        for id: UUID
    ) -> Bool {
        guard var entry = requests[id] else { return false }
        entry.onDiscard = onDiscard
        requests[id] = entry
        return true
    }

    /// Discards one reservation without disturbing unrelated in-flight policy work.
    @discardableResult
    func discard(_ id: UUID) -> Bool {
        guard let identity = discardRequest(id) else { return false }
        drainCompletedRequests(for: identity)
        return true
    }

    func claim(_ id: UUID?) -> Bool {
        guard let id else { return true }
        guard let entry = requests.removeValue(forKey: id) else { return false }
        decrementIndexes(for: entry.request, tabId: entry.indexedTabId)
        drainCompletedRequests(for: entry.deliveryIdentity)
        return true
    }

    /// Completes one asynchronous policy evaluation while preserving order
    /// within its delivery target without blocking unrelated workspaces.
    func complete(_ id: UUID, apply: @escaping @MainActor () -> Void) {
        guard var entry = requests[id] else { return }
        entry.completion = apply
        requests[id] = entry
        drainCompletedRequests(for: entry.deliveryIdentity)
    }

    func hasPendingRequest(forTabId tabId: UUID) -> Bool {
        (requestCountByTabId[tabId] ?? 0) > 0
    }

    func hasPendingRequest(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        (requestCountByTabSurface[tabId]?[surfaceId] ?? 0) > 0
    }

    func discardAll(through generation: UInt64? = nil) {
        let ids: [UUID] = requests.compactMap { id, entry -> UUID? in
            if let generation, entry.generation > generation { return nil }
            return id
        }
        let identities = Set(ids.compactMap(discardRequest))
        if generation == nil {
            evictionOrder.removeAll(keepingCapacity: true)
            evictionOrderOffset = 0
        }
        identities.forEach(drainCompletedRequests)
    }

    /// Discards requests by their current indexed owner and either canonical
    /// surface identifier, including panel/runtime-surface aliases.
    func discard(forTabId tabId: UUID, surfaceId: UUID?, through generation: UInt64? = nil) {
        let idsToDiscard: [UUID] = requests.compactMap { id, entry in
            if let generation, entry.generation > generation { return nil }
            guard entry.indexedTabId == tabId else { return nil }
            guard let surfaceId else { return id }
            return Self.matchesSurfaceAlias(entry.request, surfaceId: surfaceId) ? id : nil
        }
        let identities = Set(idsToDiscard.compactMap(discardRequest))
        identities.forEach(drainCompletedRequests)
    }

    /// Moves pending trusted-local work with the surface so O(1) unread and
    /// dismissal gates always reflect the workspace that currently owns it.
    func rebindSurface(fromTabId sourceTabId: UUID, toTabId destinationTabId: UUID, surfaceId: UUID) {
        guard sourceTabId != destinationTabId else { return }
        let idsToRebind = requests.compactMap { id, entry -> UUID? in
            guard entry.indexedTabId == sourceTabId,
                  entry.request.retargetsToLiveSurfaceOwner,
                  Self.matchesSurfaceAlias(entry.request, surfaceId: surfaceId) else {
                return nil
            }
            return id
        }
        for id in idsToRebind {
            guard var entry = requests[id] else { continue }
            decrementIndexes(for: entry.request, tabId: entry.indexedTabId)
            entry.indexedTabId = destinationTabId
            requests[id] = entry
            incrementIndexes(for: entry.request, tabId: destinationTabId)
        }
    }

    private static func matchesSurfaceAlias(
        _ request: TerminalNotificationPolicyRequest,
        surfaceId: UUID
    ) -> Bool {
        request.surfaceId == surfaceId || request.panelId == surfaceId
    }

    private func discardRequest(_ id: UUID) -> TerminalNotificationPolicyDeliveryIdentity? {
        guard let entry = requests.removeValue(forKey: id) else { return nil }
        decrementIndexes(for: entry.request, tabId: entry.indexedTabId)
        entry.task?.cancel()
        entry.onDiscard()
        return entry.deliveryIdentity
    }

    private func drainCompletedRequests(
        for deliveryIdentity: TerminalNotificationPolicyDeliveryIdentity
    ) {
        while let id = firstRequestID(for: deliveryIdentity) {
            guard let entry = requests[id] else {
                advanceRequestOffset(for: deliveryIdentity)
                continue
            }
            guard let completion = entry.completion else { break }
            requests.removeValue(forKey: id)
            decrementIndexes(for: entry.request, tabId: entry.indexedTabId)
            advanceRequestOffset(for: deliveryIdentity)
            completion()
        }
        compactRequestOrderIfNeeded(for: deliveryIdentity)
    }

    private func firstRequestID(
        for deliveryIdentity: TerminalNotificationPolicyDeliveryIdentity
    ) -> UUID? {
        guard let order = requestIDsByDeliveryIdentity[deliveryIdentity] else { return nil }
        let offset = requestOffsetByDeliveryIdentity[deliveryIdentity] ?? 0
        guard offset < order.count else { return nil }
        return order[offset]
    }

    private func advanceRequestOffset(
        for deliveryIdentity: TerminalNotificationPolicyDeliveryIdentity
    ) {
        requestOffsetByDeliveryIdentity[deliveryIdentity, default: 0] += 1
    }

    private func incrementIndexes(for request: TerminalNotificationPolicyRequest, tabId: UUID) {
        requestCountByTabId[tabId, default: 0] += 1
        let surfaceIds = Set([request.surfaceId, request.panelId].compactMap { $0 })
        if surfaceIds.isEmpty {
            requestCountByTabSurface[tabId, default: [:]][nil, default: 0] += 1
        }
        for surfaceId in surfaceIds {
            requestCountByTabSurface[tabId, default: [:]][surfaceId, default: 0] += 1
        }
    }

    private func decrementIndexes(for request: TerminalNotificationPolicyRequest, tabId: UUID) {
        Self.decrement(&requestCountByTabId, key: tabId)
        let surfaceIds = Set([request.surfaceId, request.panelId].compactMap { $0 })
        if surfaceIds.isEmpty {
            decrementSurfaceCount(tabId: tabId, surfaceId: nil)
        }
        for surfaceId in surfaceIds {
            decrementSurfaceCount(tabId: tabId, surfaceId: surfaceId)
        }
    }

    private func decrementSurfaceCount(tabId: UUID, surfaceId: UUID?) {
        guard var counts = requestCountByTabSurface[tabId] else { return }
        Self.decrement(&counts, key: surfaceId)
        if counts.isEmpty {
            requestCountByTabSurface.removeValue(forKey: tabId)
        } else {
            requestCountByTabSurface[tabId] = counts
        }
    }

    private static func decrement<Key: Hashable>(_ counts: inout [Key: Int], key: Key) {
        guard let count = counts[key] else { return }
        if count <= 1 {
            counts.removeValue(forKey: key)
        } else {
            counts[key] = count - 1
        }
    }

    private func compactEvictionOrderIfNeeded() {
        guard evictionOrder.count > maximumRequestCount * 2 else { return }
        evictionOrder = evictionOrder.dropFirst(evictionOrderOffset).filter { requests[$0] != nil }
        evictionOrderOffset = 0
    }

    private func compactRequestOrderIfNeeded(
        for deliveryIdentity: TerminalNotificationPolicyDeliveryIdentity
    ) {
        guard let order = requestIDsByDeliveryIdentity[deliveryIdentity] else { return }
        let offset = requestOffsetByDeliveryIdentity[deliveryIdentity] ?? 0
        if offset >= order.count {
            requestIDsByDeliveryIdentity.removeValue(forKey: deliveryIdentity)
            requestOffsetByDeliveryIdentity.removeValue(forKey: deliveryIdentity)
        } else if offset > 64, offset * 2 >= order.count {
            requestIDsByDeliveryIdentity[deliveryIdentity] = Array(order.dropFirst(offset))
            requestOffsetByDeliveryIdentity[deliveryIdentity] = 0
        }
    }
}
