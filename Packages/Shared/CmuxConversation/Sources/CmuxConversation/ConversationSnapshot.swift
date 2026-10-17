public import Foundation

/// A complete point-in-time projection plus the cursor needed for replay.
public struct ConversationSnapshot: Codable, Hashable, Sendable {
    /// Session metadata.
    public let session: ConversationSession
    /// Cursor represented by this snapshot.
    public let cursor: ConversationCursor
    /// Generation represented by this snapshot.
    public let generation: ConversationGeneration
    /// Ordered items in the current projection.
    public var items: [ConversationItem]
    /// Requests still requiring user action.
    public var pendingRequests: [ConversationRequest]
    /// Queued turns.
    public var queued: [ConversationQueueItem]
    /// Recent command receipts for reconciliation.
    public var receipts: [ConversationReceipt]
    /// Provider capabilities.
    public let capabilities: ConversationCapabilities

    /// Creates a conversation snapshot.
    public init(session: ConversationSession, cursor: ConversationCursor, generation: ConversationGeneration, items: [ConversationItem] = [], pendingRequests: [ConversationRequest] = [], queued: [ConversationQueueItem] = [], receipts: [ConversationReceipt] = [], capabilities: ConversationCapabilities) { self.session = session; self.cursor = cursor; self.generation = generation; self.items = items; self.pendingRequests = pendingRequests; self.queued = queued; self.receipts = receipts; self.capabilities = capabilities }
}
