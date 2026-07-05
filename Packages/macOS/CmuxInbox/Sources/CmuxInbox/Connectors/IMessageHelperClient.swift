import Foundation

/// Process seam for the external `cmux-imsg` helper.
public protocol IMessageHelperClient: Sendable {
    /// Returns helper status.
    func status() async -> IMessageHelperStatus

    /// Syncs recent helper messages.
    func recent(cursor: String?) async throws -> InboxConnectorSyncResult

    /// Sends an approved iMessage reply through the helper.
    func sendApprovedReply(draft: InboxDraft, thread: InboxThread) async throws
}
