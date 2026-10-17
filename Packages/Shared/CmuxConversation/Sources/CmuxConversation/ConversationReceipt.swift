public import Foundation

/// Outcome of one durable command attempt.
public enum ConversationReceiptState: String, Codable, Hashable, Sendable { case accepted, applied, rejected, uncertain }

/// A durable command receipt; uncertain receipts require explicit reconciliation.
public struct ConversationReceipt: Codable, Hashable, Sendable, Identifiable {
    /// Command identity.
    public let id: ConversationCommandID
    /// Session receiving the command.
    public let sessionID: ConversationID
    /// Receipt outcome.
    public var state: ConversationReceiptState
    /// Human-readable reason for rejection or uncertainty.
    public var reason: String?
    /// Event cursor associated with application, if known.
    public var eventSequence: ConversationCursor?
    /// Generation in which the command was evaluated.
    public var generation: ConversationGeneration
    /// Draft text restored to the composer when a queued command is cancelled.
    public var draftText: String?
    /// Time at which the receipt was written.
    public let createdAt: Date

    /// Creates a receipt.
    public init(id: ConversationCommandID, sessionID: ConversationID, state: ConversationReceiptState, reason: String? = nil, eventSequence: ConversationCursor? = nil, generation: ConversationGeneration, draftText: String? = nil, createdAt: Date = Date()) { self.id = id; self.sessionID = sessionID; self.state = state; self.reason = reason; self.eventSequence = eventSequence; self.generation = generation; self.draftText = draftText; self.createdAt = createdAt }
}
