public import Foundation

/// One durable report read from the local ACPMUX reports mailbox.
///
/// Reports are a separate projection from the cloud feed: they do not enter
/// feed triage or wake an agent session. `sender` is the daemon-qualified
/// ACPMUX session identity used to address a reply.
public nonisolated struct FeedReport: Sendable, Equatable, Identifiable {
    public let id: String
    public let sender: String
    public let body: String
    public let createdAt: Date

    public init(id: String, sender: String, body: String, createdAt: Date) {
        self.id = id
        self.sender = sender
        self.body = body
        self.createdAt = createdAt
    }
}
