import Foundation

/// One sub-session of a chat, as `_acpmux/chat_subsessions` answers it (`cmux_chat_index::SubSession`): a Claude
/// Code subagent or a Codex spawned thread, read from the harness's own store.
public nonisolated struct AcpmuxSubSession: Hashable, Sendable {
    public var id: String
    /// The sub-session that started it; nil when the chat itself did.
    public var parentID: String?
    public var title: String?
    public var kind: String?
    /// `running`, `done`, `failed` or `idle`.
    public var state: String
    public var depth: Int
    public var updatedMs: Int64

    public init(id: String, parentID: String? = nil, title: String? = nil, kind: String? = nil, state: String = "idle",
                depth: Int = 1, updatedMs: Int64 = 0) {
        self.id = id
        self.parentID = parentID
        self.title = title
        self.kind = kind
        self.state = state
        self.depth = depth
        self.updatedMs = updatedMs
    }

    /// One row of the answer; nil without an id.
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        let text = { (key: String) in (json[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        self.init(id: id, parentID: text("parentId"), title: text("title"), kind: text("kind"), state: text("state") ?? "idle",
                  depth: (json["depth"] as? NSNumber)?.intValue ?? 1, updatedMs: (json["updatedMs"] as? NSNumber)?.int64Value ?? 0)
    }
}
