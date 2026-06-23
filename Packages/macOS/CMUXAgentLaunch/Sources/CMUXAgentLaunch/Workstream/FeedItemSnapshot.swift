import Foundation

/// Immutable `Equatable` projection of a ``WorkstreamItem`` handed to feed row
/// views so rows never hold a reference to the store.
///
/// Every field is a value copied from the source item at construction time,
/// plus ``userPromptEcho``, which the list view attaches so each card can show
/// a "You: …" echo for context even when the agent payload doesn't carry it
/// directly. Because the snapshot is a pure value, a row view can diff against
/// the previous snapshot and re-render only on a real change, and it never
/// observes the live store.
public struct FeedItemSnapshot: Equatable, Sendable {
    /// Stable identity of the source ``WorkstreamItem``.
    public let id: UUID
    /// ID grouping items that belong to the same agent session.
    public let workstreamId: String
    /// Origin agent/integration that emitted the item.
    public let source: WorkstreamSource
    /// Event category (telemetry vs actionable kind).
    public let kind: WorkstreamKind
    /// Human-readable title, when the source provided one.
    public let title: String?
    /// Working directory associated with the item, when known.
    public let cwd: String?
    /// Creation timestamp of the source item.
    public let createdAt: Date
    /// Lifecycle state of the source item.
    public let status: WorkstreamStatus
    /// Structured payload carried by the source item.
    public let payload: WorkstreamPayload
    /// Extra nearby conversation context, when attached.
    public let context: WorkstreamContext?
    /// Most recent user-prompt text in the same workstream, attached by the
    /// list view so every card can show a "You: …" echo for context, even when
    /// the agent payload doesn't carry it directly.
    public let userPromptEcho: String?

    /// Projects an immutable snapshot from a live ``WorkstreamItem``.
    ///
    /// - Parameters:
    ///   - item: The source item whose value fields are copied.
    ///   - userPromptEcho: The most recent user-prompt text in the same
    ///     workstream, supplied by the list view; defaults to `nil`.
    public init(item: WorkstreamItem, userPromptEcho: String? = nil) {
        self.id = item.id
        self.workstreamId = item.workstreamId
        self.source = item.source
        self.kind = item.kind
        self.title = item.title
        self.cwd = item.cwd
        self.createdAt = item.createdAt
        self.status = item.status
        self.payload = item.payload
        self.context = item.context
        self.userPromptEcho = userPromptEcho
    }
}
