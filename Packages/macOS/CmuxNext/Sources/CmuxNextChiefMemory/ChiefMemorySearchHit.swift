/// One full-text search hit in a Chief's memory: a message or a summary line.
public struct ChiefMemorySearchHit: Sendable, Equatable, Identifiable, Decodable {
    /// The node to open for it (a message's own line is `id+1`).
    public var name: String
    /// `message` or `node`.
    public var type: String
    /// The matched text around the words.
    public var snippet: String

    public var id: String { "\(type):\(name)" }

    public init(name: String, type: String, snippet: String) {
        self.name = name
        self.type = type
        self.snippet = snippet
    }
}
