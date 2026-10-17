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
    /// Active native turn identity, when a turn is running.
    public let activeTurnID: ConversationTurnID?
    /// Whether a provider turn is currently running or dispatching.
    public let isTurnRunning: Bool
    /// Provider capabilities.
    public let capabilities: ConversationCapabilities

    /// Creates a conversation snapshot.
    public init(session: ConversationSession, cursor: ConversationCursor, generation: ConversationGeneration, items: [ConversationItem] = [], pendingRequests: [ConversationRequest] = [], queued: [ConversationQueueItem] = [], receipts: [ConversationReceipt] = [], activeTurnID: ConversationTurnID? = nil, isTurnRunning: Bool = false, capabilities: ConversationCapabilities) { self.session = session; self.cursor = cursor; self.generation = generation; self.items = items; self.pendingRequests = pendingRequests; self.queued = queued; self.receipts = receipts; self.activeTurnID = activeTurnID; self.isTurnRunning = isTurnRunning; self.capabilities = capabilities }
    /// Decodes snapshots written by older brokers, defaulting newly added lifecycle fields safely.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try c.decode(ConversationSession.self, forKey: .session)
        cursor = try c.decode(ConversationCursor.self, forKey: .cursor)
        generation = try c.decode(ConversationGeneration.self, forKey: .generation)
        items = try c.decodeIfPresent([ConversationItem].self, forKey: .items) ?? []
        pendingRequests = try c.decodeIfPresent([ConversationRequest].self, forKey: .pendingRequests) ?? []
        queued = try c.decodeIfPresent([ConversationQueueItem].self, forKey: .queued) ?? []
        receipts = try c.decodeIfPresent([ConversationReceipt].self, forKey: .receipts) ?? []
        activeTurnID = try c.decodeIfPresent(ConversationTurnID.self, forKey: .activeTurnID)
        isTurnRunning = try c.decodeIfPresent(Bool.self, forKey: .isTurnRunning) ?? false
        capabilities = try c.decode(ConversationCapabilities.self, forKey: .capabilities)
    }

    private enum CodingKeys: String, CodingKey { case session, cursor, generation, items, pendingRequests, queued, receipts, activeTurnID, isTurnRunning, capabilities }

}
