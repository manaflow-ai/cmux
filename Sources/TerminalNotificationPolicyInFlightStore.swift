import Foundation

/// Tracks notification-policy evaluations across their asynchronous hook
/// boundary so a clear can invalidate work that has left the mutation queue
/// but has not yet applied to the notification store.
@MainActor
final class TerminalNotificationPolicyInFlightStore {
    private var requests: [UUID: TerminalNotificationPolicyRequest] = [:]

    func register(_ request: TerminalNotificationPolicyRequest) -> UUID {
        let id = UUID()
        requests[id] = request
        return id
    }

    func claim(_ id: UUID?) -> Bool {
        guard let id else { return true }
        return requests.removeValue(forKey: id) != nil
    }

    func discardAll() {
        requests.removeAll()
    }

    func discard(forTabId tabId: UUID, surfaceId: UUID?) {
        requests = requests.filter { _, request in
            if let surfaceId {
                return request.surfaceId != surfaceId
            }
            let liveTabId = AppDelegate.shared?.agentNotificationDeliveryTarget(
                claimedTabId: request.tabId,
                surfaceId: request.surfaceId
            )?.tabId ?? request.tabId
            return request.tabId != tabId && liveTabId != tabId
        }
    }
}
