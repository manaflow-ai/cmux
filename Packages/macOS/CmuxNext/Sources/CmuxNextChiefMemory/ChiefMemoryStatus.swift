/// The counts at the top of the Memory Inspector.
public struct ChiefMemoryStatus: Sendable, Equatable, Decodable {
    /// Messages in the log.
    public var messages: UInt64
    /// Summary lines built.
    public var nodesBuilt: UInt64
    /// Lines waiting to be rebuilt after a change.
    public var stale: [String]
    /// Whether this brain takes changes (an older brain is read-only).
    public var editable: Bool

    public init(messages: UInt64, nodesBuilt: UInt64, stale: [String] = [], editable: Bool = true) {
        self.messages = messages
        self.nodesBuilt = nodesBuilt
        self.stale = stale
        self.editable = editable
    }

    enum CodingKeys: String, CodingKey {
        case messages, stale, editable
        case nodesBuilt = "nodes_built"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decodeIfPresent(UInt64.self, forKey: .messages) ?? 0
        nodesBuilt = try c.decodeIfPresent(UInt64.self, forKey: .nodesBuilt) ?? 0
        stale = try c.decodeIfPresent([String].self, forKey: .stale) ?? []
        editable = try c.decodeIfPresent(Bool.self, forKey: .editable) ?? false
    }
}
