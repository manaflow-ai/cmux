public import Foundation

/// A local reply draft that can only be sent after visible user approval.
public struct InboxDraft: Codable, Equatable, Identifiable, Sendable {
    /// Local stable draft id.
    public let draftID: String
    /// Local thread id this draft replies to.
    public let threadID: String
    /// Source service for the target thread.
    public let source: InboxSource
    /// Source-specific account id.
    public let accountID: String
    /// Optional drafting instruction supplied by the user.
    public var instruction: String?
    /// Draft body shown to the user before approval.
    public var body: String
    /// Local lifecycle state.
    public var status: InboxDraftStatus
    /// Draft creation timestamp.
    public var createdAt: Date
    /// Timestamp when the user approved sending.
    public var approvedAt: Date?
    /// Timestamp when the connector reported success.
    public var sentAt: Date?
    /// User-safe error text if sending failed.
    public var errorMessage: String?

    /// Stable identity used by SwiftUI lists.
    public var id: String { draftID }

    /// Creates a local reply draft.
    public init(
        draftID: String,
        threadID: String,
        source: InboxSource,
        accountID: String,
        instruction: String? = nil,
        body: String,
        status: InboxDraftStatus = .editing,
        createdAt: Date,
        approvedAt: Date? = nil,
        sentAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.draftID = draftID
        self.threadID = threadID
        self.source = source
        self.accountID = accountID
        self.instruction = instruction
        self.body = body
        self.status = status
        self.createdAt = createdAt
        self.approvedAt = approvedAt
        self.sentAt = sentAt
        self.errorMessage = errorMessage
    }
}
