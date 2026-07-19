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
    }
    private let maximumRequestCount = 1_024
    private var requests: [UUID: Entry] = [:]
    private var requestOrder: [UUID] = []
    private var requestOrderOffset = 0

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
        let id = UUID()
        requests[id] = Entry(request: request, generation: generation, onDiscard: onDiscard, task: nil)
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
        return requests.removeValue(forKey: id) != nil
    }

    func discardAll(through generation: UInt64? = nil) {
        let ids: [UUID] = requests.compactMap { id, entry -> UUID? in
            if let generation, entry.generation > generation { return nil }
            return id
        }
        ids.forEach(discardRequest)
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
    }

    private func discardRequest(_ id: UUID) {
        guard let entry = requests.removeValue(forKey: id) else { return }
        entry.task?.cancel()
        entry.onDiscard()
    }

    private func compactRequestOrderIfNeeded() {
        guard requestOrder.count > maximumRequestCount * 2 else { return }
        requestOrder = requestOrder.dropFirst(requestOrderOffset).filter { requests[$0] != nil }
        requestOrderOffset = 0
    }
}
