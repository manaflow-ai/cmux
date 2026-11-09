public import CmuxNextDaemon
import Foundation

/// The person's reads of this daemon's tabs (``TabReads``): shown at once and sent until the daemon answers, so a
/// daemon that is down, reconnecting or still restoring never brings a read dot back. A teardown of this service
/// ends them.
extension DaemonService {
    /// Reads `tab`'s unread notification (``TabReads/readNotification(of:alive:answered:_:)``); `answered` gets the
    /// daemon's reply. A tab with no marker to read is acknowledged once, as before.
    public func readNotification(of tab: TabModel,
                                 answered: @escaping @MainActor (AckTabNotificationsRequest.Response) -> Void = { _ in }) {
        let start = shutdowns
        let sent = reads.readNotification(of: tab, alive: { [weak self] in self?.shutdowns == start }, answered: answered) { [weak self] surface in
            guard let self else { throw CancellationError() }
            return try await perform("ack-tab-notifications") { try await $0.acknowledgeNotifications(of: surface) }
        }
        guard sent == nil, tab.readingNotification == nil else { return }
        let surface = tab.surface
        send("ack-tab-notifications") { _ = try await $0.acknowledgeNotifications(of: surface) }
    }

    /// Clears `tab`'s Mark as Unread on its record (`resource`), sent until answered.
    public func clearMarkedUnread(of tab: TabModel, resource: ResourceID) {
        let start = shutdowns
        reads.clearMarkedUnread(of: tab, alive: { [weak self] in self?.shutdowns == start }) { [weak self] in
            guard let self else { throw CancellationError() }
            try await perform("tab.update") { try await $0.state.updateTabRecord(resource, markedUnread: false) }
        }
    }

    /// Clears the agent's mark `request` on `tab`'s record (`resource`), sent until answered.
    public func clearAttention(_ request: TabAttention, of tab: TabModel, resource: ResourceID) {
        let start = shutdowns
        reads.clearAttention(request, of: tab, alive: { [weak self] in self?.shutdowns == start }) { [weak self] in
            guard let self else { throw CancellationError() }
            try await perform("tab.update") { try await $0.state.updateTabRecord(resource, attentionRequestID: request.requestID) }
        }
    }
}
