import Foundation

/// Immutable snapshot of a `WorkstreamItem` handed to row views so rows
/// never hold a reference to the store.
public struct FeedItemSnapshot: Equatable {
    public let id: UUID
    public let workstreamId: String
    public let source: WorkstreamSource
    public let kind: WorkstreamKind
    public let title: String?
    public let cwd: String?
    public let createdAt: Date
    public let status: WorkstreamStatus
    public let payload: WorkstreamPayload
    public let context: WorkstreamContext?
    /// Most recent user-prompt text in the same workstream, attached
    /// by the list view so every card can show a "You: …" echo for
    /// context, even when the agent payload doesn't carry it directly.
    public let userPromptEcho: String?

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

    /// Walks the full items list (not just the filtered visible set),
    /// ordered by createdAt, and records the most recent user-prompt
    /// text per workstreamId. Rows consult this dict to show a
    /// "You: …" echo line at the top of their card.
    public static func lastPromptByWorkstream(_ items: [WorkstreamItem]) -> [String: String] {
        var out: [String: String] = [:]
        for item in items {
            if case .userPrompt(let text) = item.payload, !text.isEmpty {
                out[item.workstreamId] = text
            }
        }
        return out
    }
}
