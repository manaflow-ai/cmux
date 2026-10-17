public import Foundation

/// Compact updates keep streaming journal and replay size proportional to new content.
public enum ConversationItemUpdateMode: String, Codable, Hashable, Sendable {
    /// Append `item.text` (and plan text when present) to the existing item.
    case appendText
    /// Append the string in `item.tool.output` to the existing tool output.
    case appendToolOutput
}

/// The normalized lifecycle category for a journal event.
public enum ConversationEventKind: Hashable, Sendable, Codable {
    /// An item was added or updated.
    case item
    /// A turn started or completed.
    case turn
    /// Run lifecycle changed.
    case run
    /// An approval or question changed.
    case request
    /// Queue contents changed.
    case queue
    /// A command receipt was persisted.
    case receipt
    /// Provider process restarted and generation changed.
    case restarted
    /// A provider payload has no normalized category.
    case unknown(String)

    public var rawValue: String { switch self { case .item: "item"; case .turn: "turn"; case .run: "run"; case .request: "request"; case .queue: "queue"; case .receipt: "receipt"; case .restarted: "restarted"; case .unknown(let value): value } }
    public init(rawValue: String) { switch rawValue { case "item": self = .item; case "turn": self = .turn; case "run": self = .run; case "request": self = .request; case "queue": self = .queue; case "receipt": self = .receipt; case "restarted": self = .restarted; default: self = .unknown(rawValue) } }
    public init(from decoder: any Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

/// One ordered journal record sent to clients.
public struct ConversationEvent: Codable, Hashable, Sendable, Identifiable {
    /// Session that emitted this event.
    public let sessionID: ConversationID
    /// Monotonic journal sequence.
    public let sequence: ConversationCursor
    /// Provider generation at emission.
    public let generation: ConversationGeneration
    /// Event timestamp.
    public let timestamp: Date
    /// Normalized category.
    public let kind: ConversationEventKind
    /// Owning turn, when known.
    public let turnID: ConversationTurnID?
    /// Item payload when `kind` is item.
    public let item: ConversationItem?
    /// Nil replaces an item; a mode applies a compact delta to the prior item.
    public let itemUpdate: ConversationItemUpdateMode?
    /// Request payload when `kind` is request.
    public let request: ConversationRequest?
    /// Queue payload when `kind` is queue.
    public let queue: [ConversationQueueItem]?
    /// Receipt payload when `kind` is receipt.
    public let receipt: ConversationReceipt?
    /// Run or turn state label.
    public let state: String?
    /// Original provider event payload.
    public let rawPayload: ConversationJSONValue?

    /// Uses the journal sequence as a stable event identity.
    public var id: ConversationCursor { sequence }

    /// Creates an ordered event.
    public init(sessionID: ConversationID, sequence: ConversationCursor, generation: ConversationGeneration, timestamp: Date = Date(), kind: ConversationEventKind, turnID: ConversationTurnID? = nil, item: ConversationItem? = nil, itemUpdate: ConversationItemUpdateMode? = nil, request: ConversationRequest? = nil, queue: [ConversationQueueItem]? = nil, receipt: ConversationReceipt? = nil, state: String? = nil, rawPayload: ConversationJSONValue? = nil) { self.sessionID = sessionID; self.sequence = sequence; self.generation = generation; self.timestamp = timestamp; self.kind = kind; self.turnID = turnID; self.item = item; self.itemUpdate = itemUpdate; self.request = request; self.queue = queue; self.receipt = receipt; self.state = state; self.rawPayload = rawPayload }
}
