/// Everything a GUI shows for one conversation, folded from its events.
///
/// Build it with ``ConversationReducer``. It is a value: a view model holds
/// one and replaces it on every change, so SwiftUI and AppKit observe a
/// consistent snapshot.
///
/// ```swift
/// var state = ConversationState()
/// let reducer = ConversationReducer()
/// reducer.apply(page, to: &state)       // history
/// reducer.apply([live], to: &state)     // one live event
/// ```
public struct ConversationState: Hashable, Sendable {
    /// The timeline, oldest first, including messages sent from this device
    /// that the backend has not confirmed yet.
    public internal(set) var items: [ConversationItem] = []
    /// Attached files by upload identifier.
    public internal(set) var attachments: [String: ConversationAttachment] = [:]
    /// Messages waiting their turn, in order.
    public internal(set) var queue: [QueuedPrompt] = []
    /// What the agent is doing.
    public internal(set) var status: ConversationStatus = .idle
    /// The conversation's title, once known.
    public internal(set) var title: String?
    /// The agent's mode, once known.
    public internal(set) var mode: String?
    /// The agent's model, once known.
    public internal(set) var model: String?
    /// Context-window use as (used, size), when reported.
    public internal(set) var usage: Usage?
    /// Older history exists on the backend that is not loaded yet.
    public internal(set) var hasOlder: Bool = false

    /// Context-window use.
    public struct Usage: Hashable, Sendable {
        /// Tokens in use.
        public var used: UInt64
        /// Window size, when known.
        public var size: UInt64?
    }

    /// Creates an empty state.
    public init() {}

    /// Every loaded event, ordered by cursor; refolded when an older page lands.
    var log: [ConversationEnvelope] = []
    /// Messages sent from this device, kept until the backend confirms them.
    var localSends: [ClientMessageID: LocalSend] = [:]
    /// Order in which local sends were made.
    var localOrder: [ClientMessageID] = []

    /// A message sent from this device that the backend has not confirmed.
    struct LocalSend: Hashable, Sendable {
        var message: OutgoingMessage
        var failed: Bool
    }

    /// The newest loaded position, if any.
    public var newestCursor: ConversationCursor? { log.last?.cursor }
    /// The oldest loaded position, if any.
    public var oldestCursor: ConversationCursor? { log.first?.cursor }
    /// The approval request that still waits for an answer, if any.
    public var pendingApproval: ApprovalRequest? {
        for item in items.reversed() {
            if case let .approval(r) = item.kind, r.isPending { return r }
        }
        return nil
    }
    /// Whether the backend deleted the conversation.
    public var isDeleted: Bool { status == .deleted }
}
