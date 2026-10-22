/// One entry the agent memory index found (`optchat-chief agent-memory search --json`).
public nonisolated struct AgentMemoryHit: Sendable, Equatable, Decodable {
    /// The entry's id in the index (`agent-memory get ID`).
    public var id: Int
    /// What the entry is, such as `memory` or `note`.
    public var kind: String
    /// The entry's date as the index reports it.
    public var date: String
    /// Where the entry came from (a memory file label or `note`).
    public var source: String
    /// The matching words in `[` `]` with some context; empty when the index has none.
    public var snippet: String
    /// The entry's full text.
    public var text: String

    /// Creates a hit as the index reports it.
    /// - Parameters:
    ///   - id: The entry's id in the index.
    ///   - kind: What the entry is.
    ///   - date: The entry's date.
    ///   - source: Where the entry came from.
    ///   - snippet: The matching words with context.
    ///   - text: The entry's full text.
    public init(id: Int, kind: String, date: String, source: String, snippet: String, text: String) {
        self.id = id
        self.kind = kind
        self.date = date
        self.source = source
        self.snippet = snippet
        self.text = text
    }

    /// The hit in the Agent Memory app's `memory.search` shape: the index is
    /// one root, `agent-memory`, whose paths are the hits' sources; entries
    /// have no line numbers. `id` and `date` ride along for the app.
    var appHit: AppJSON {
        [
            "root": "agent-memory",
            "path": .string(source),
            "line": 0,
            "text": .string(snippet.isEmpty ? text : snippet),
            "id": .number(Double(id)),
            "date": .string(date),
        ]
    }
}
