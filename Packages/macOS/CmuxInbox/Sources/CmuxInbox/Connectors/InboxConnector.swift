import Foundation

/// Connector contract between external services and the local cmux inbox.
public protocol InboxConnector: Sendable {
    /// Source service owned by the connector.
    var source: InboxSource { get }
    /// Capabilities supported by this connector.
    var capabilities: Set<InboxConnectorCapability> { get }

    /// Returns current user-safe status.
    func status() async -> InboxConnectorStatus

    /// Performs a backfill or incremental sync.
    /// - Parameter cursor: Optional last sync cursor.
    func sync(cursor: String?) async throws -> InboxConnectorSyncResult

    /// Returns a live event stream when supported.
    func events() -> AsyncStream<InboxConnectorEvent>

    /// Marks an item or thread read when supported.
    func markRead(thread: InboxThread?, item: InboxItem?) async throws

    /// Creates a local reply draft body.
    func draftReply(thread: InboxThread, recentItems: [InboxItem], instruction: String?) async throws -> String

    /// Sends a user-approved draft.
    func sendApprovedReply(draft: InboxDraft, thread: InboxThread) async throws
}

public extension InboxConnector {
    /// Default empty live stream for connectors without live event support.
    func events() -> AsyncStream<InboxConnectorEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    /// Default unsupported mark-read behavior.
    func markRead(thread: InboxThread?, item: InboxItem?) async throws {
        throw InboxError.unsupported("\(source.rawValue) does not support mark-read")
    }

    /// Default draft generation uses the latest local context as a simple editable draft.
    func draftReply(thread: InboxThread, recentItems: [InboxItem], instruction: String?) async throws -> String {
        if let instruction, !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return instruction
        }
        let latest = recentItems.last?.bodyPreview ?? thread.title
        return "Reply to: \(latest)"
    }

    /// Default unsupported send behavior.
    func sendApprovedReply(draft: InboxDraft, thread: InboxThread) async throws {
        throw InboxError.unsupported("\(source.rawValue) does not support replies")
    }
}
