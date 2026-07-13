import Foundation

/// Tracks notification-policy evaluations across their asynchronous hook
/// boundary so a clear can invalidate work that has left the mutation queue
/// but has not yet applied to the notification store.
@MainActor
final class TerminalNotificationPolicyInFlightStore {
    private struct Entry {
        let request: TerminalNotificationPolicyRequest
        let generation: UInt64
    }
    private let maximumRequestCount = 1_024
    private var requests: [UUID: Entry] = [:]
    private var requestOrder: [UUID] = []
    private var requestOrderOffset = 0

    func register(_ request: TerminalNotificationPolicyRequest, generation: UInt64) -> UUID {
        compactRequestOrderIfNeeded()
        while requests.count >= maximumRequestCount, requestOrderOffset < requestOrder.count {
            requests.removeValue(forKey: requestOrder[requestOrderOffset])
            requestOrderOffset += 1
        }
        let id = UUID()
        requests[id] = Entry(request: request, generation: generation)
        requestOrder.append(id)
        return id
    }

    func claim(_ id: UUID?) -> Bool {
        guard let id else { return true }
        return requests.removeValue(forKey: id) != nil
    }

    func discardAll(through generation: UInt64? = nil) {
        guard let generation else {
            requests.removeAll()
            requestOrder.removeAll(keepingCapacity: true)
            requestOrderOffset = 0
            return
        }
        requests = requests.filter { $0.value.generation > generation }
    }

    /// Discards requests by their delivery identity: source-confined requests
    /// keep their original workspace key, while trusted local requests follow
    /// their surface's live owner.
    func discard(forTabId tabId: UUID, surfaceId: UUID?, through generation: UInt64? = nil) {
        var resolvedSurfaces = Set<UUID>()
        var liveOwnersBySurface: [UUID: UUID] = [:]
        requests = requests.filter { _, entry in
            if let generation, entry.generation > generation { return true }
            let request = entry.request
            if !request.retargetsToLiveSurfaceOwner {
                if let surfaceId {
                    return request.tabId != tabId || request.surfaceId != surfaceId
                }
                return request.tabId != tabId
            }
            if let surfaceId {
                return request.surfaceId != surfaceId
            }
            guard let requestSurfaceId = request.surfaceId else { return request.tabId != tabId }
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
            return liveTabId != tabId
        }
    }

    private func compactRequestOrderIfNeeded() {
        guard requestOrder.count > maximumRequestCount * 2 else { return }
        requestOrder = requestOrder.dropFirst(requestOrderOffset).filter { requests[$0] != nil }
        requestOrderOffset = 0
    }
}
