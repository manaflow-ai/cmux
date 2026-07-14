import Foundation

/// Tracks notification-policy evaluations across their asynchronous hook
/// boundary so a clear can invalidate work that has left the mutation queue
/// but has not yet applied to the notification store.
@MainActor
final class TerminalNotificationPolicyInFlightStore {
    private struct Entry {
        let request: TerminalNotificationPolicyRequest
        let generation: UInt64
        let onDiscard: @MainActor @Sendable () -> Void
        var task: Task<Void, Never>?
        var completion: (@MainActor () -> Void)?
    }
    private let maximumRequestCount = 1_024
    private var requests: [UUID: Entry] = [:]
    private var requestOrder: [UUID] = []
    private var requestOrderOffset = 0
    private var requestCountByTabId: [UUID: Int] = [:]
    private var requestCountByTabSurface: [UUID: [UUID?: Int]] = [:]

    func register(
        _ request: TerminalNotificationPolicyRequest,
        generation: UInt64,
        onDiscard: @escaping @MainActor @Sendable () -> Void
    ) -> UUID {
        compactRequestOrderIfNeeded()
        while requests.count >= maximumRequestCount, requestOrderOffset < requestOrder.count {
            discardRequest(requestOrder[requestOrderOffset])
            requestOrderOffset += 1
        }
        drainCompletedRequestsInOrder()
        let id = UUID()
        requests[id] = Entry(
            request: request,
            generation: generation,
            onDiscard: onDiscard,
            task: nil,
            completion: nil
        )
        incrementIndexes(for: request)
        requestOrder.append(id)
        return id
    }

    func attach(task: Task<Void, Never>, to id: UUID) {
        guard var entry = requests[id] else { task.cancel(); return }
        entry.task = task
        requests[id] = entry
    }

    func claim(_ id: UUID?) -> Bool {
        guard let id else { return true }
        guard let entry = requests.removeValue(forKey: id) else { return false }
        decrementIndexes(for: entry.request)
        drainCompletedRequestsInOrder()
        return true
    }

    /// Completes one asynchronous policy evaluation while preserving the
    /// registration order observed by synchronous notification callers.
    func complete(_ id: UUID, apply: @escaping @MainActor () -> Void) {
        guard var entry = requests[id] else { return }
        entry.completion = apply
        requests[id] = entry
        drainCompletedRequestsInOrder()
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
        ids.forEach(discardRequest)
        drainCompletedRequestsInOrder()
        if generation == nil {
            requestOrder.removeAll(keepingCapacity: true)
            requestOrderOffset = 0
        }
    }

    /// Discards requests by their delivery identity: source-confined requests
    /// keep their original workspace key, while trusted local requests follow
    /// their surface's live owner.
    func discard(forTabId tabId: UUID, surfaceId: UUID?, through generation: UInt64? = nil) {
        var resolvedSurfaces = Set<UUID>()
        var liveOwnersBySurface: [UUID: UUID] = [:]
        var idsToDiscard: [UUID] = []
        for (id, entry) in requests {
            if let generation, entry.generation > generation { continue }
            let request = entry.request
            if !request.retargetsToLiveSurfaceOwner {
                if let surfaceId {
                    if request.tabId == tabId, request.surfaceId == surfaceId { idsToDiscard.append(id) }
                } else if request.tabId == tabId {
                    idsToDiscard.append(id)
                }
                continue
            }
            if let surfaceId {
                if request.surfaceId == surfaceId { idsToDiscard.append(id) }
                continue
            }
            guard let requestSurfaceId = request.surfaceId else {
                if request.tabId == tabId { idsToDiscard.append(id) }
                continue
            }
            let liveTabId: UUID
            if resolvedSurfaces.insert(requestSurfaceId).inserted {
                let owner = AppDelegate.shared?.agentNotificationDeliveryTarget(
                    claimedTabId: request.tabId,
                    surfaceId: requestSurfaceId
                )?.tabId
                if let owner { liveOwnersBySurface[requestSurfaceId] = owner }
                liveTabId = owner ?? request.tabId
            } else {
                liveTabId = liveOwnersBySurface[requestSurfaceId] ?? request.tabId
            }
            if liveTabId == tabId { idsToDiscard.append(id) }
        }
        idsToDiscard.forEach(discardRequest)
        drainCompletedRequestsInOrder()
    }

    private func discardRequest(_ id: UUID) {
        guard let entry = requests.removeValue(forKey: id) else { return }
        decrementIndexes(for: entry.request)
        entry.task?.cancel()
        entry.onDiscard()
    }

    private func drainCompletedRequestsInOrder() {
        while requestOrderOffset < requestOrder.count {
            let id = requestOrder[requestOrderOffset]
            guard let entry = requests[id] else {
                requestOrderOffset += 1
                continue
            }
            guard let completion = entry.completion else { break }
            requests.removeValue(forKey: id)
            decrementIndexes(for: entry.request)
            requestOrderOffset += 1
            completion()
        }
        compactRequestOrderIfNeeded()
    }

    private func incrementIndexes(for request: TerminalNotificationPolicyRequest) {
        requestCountByTabId[request.tabId, default: 0] += 1
        let surfaceIds = Set([request.surfaceId, request.panelId].compactMap { $0 })
        if surfaceIds.isEmpty {
            requestCountByTabSurface[request.tabId, default: [:]][nil, default: 0] += 1
        }
        for surfaceId in surfaceIds {
            requestCountByTabSurface[request.tabId, default: [:]][surfaceId, default: 0] += 1
        }
    }

    private func decrementIndexes(for request: TerminalNotificationPolicyRequest) {
        Self.decrement(&requestCountByTabId, key: request.tabId)
        let surfaceIds = Set([request.surfaceId, request.panelId].compactMap { $0 })
        if surfaceIds.isEmpty {
            decrementSurfaceCount(tabId: request.tabId, surfaceId: nil)
        }
        for surfaceId in surfaceIds {
            decrementSurfaceCount(tabId: request.tabId, surfaceId: surfaceId)
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

    private func compactRequestOrderIfNeeded() {
        guard requestOrder.count > maximumRequestCount * 2 else { return }
        requestOrder = requestOrder.dropFirst(requestOrderOffset).filter { requests[$0] != nil }
        requestOrderOffset = 0
    }
}
