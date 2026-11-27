/// One change a person made to a Chief's memory, as the brain's change
/// journal records it.
public struct ChiefMemoryChange: Sendable, Equatable, Identifiable, Decodable {
    /// The change's id (the undo path takes it).
    public var id: UInt64
    /// When it was made (RFC 3339).
    public var at: String
    /// `edit` or `delete`.
    public var op: String
    /// What it changed.
    public var target: ChiefMemoryTarget
    /// The text before.
    public var old: String
    /// The text after.
    public var new: String
    /// Summary lines above it still waiting to be rebuilt.
    public var stale: [String]
    /// Whether it was undone.
    public var undone: Bool

    public init(id: UInt64, at: String, op: String, target: ChiefMemoryTarget, old: String, new: String,
                stale: [String] = [], undone: Bool = false) {
        self.id = id
        self.at = at
        self.op = op
        self.target = target
        self.old = old
        self.new = new
        self.stale = stale
        self.undone = undone
    }

    enum CodingKeys: String, CodingKey { case id, at, op, target, old, new, stale, undone }
    private struct Target: Decodable {
        var message: UInt64?
        var node: String?
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UInt64.self, forKey: .id)
        at = try c.decodeIfPresent(String.self, forKey: .at) ?? ""
        op = try c.decode(String.self, forKey: .op)
        let raw = try c.decode(Target.self, forKey: .target)
        if let message = raw.message {
            target = .message(message)
        } else if let node = raw.node {
            target = .line(node)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .target, in: c, debugDescription: "no message or node")
        }
        old = try c.decodeIfPresent(String.self, forKey: .old) ?? ""
        new = try c.decodeIfPresent(String.self, forKey: .new) ?? ""
        stale = try c.decodeIfPresent([String].self, forKey: .stale) ?? []
        undone = try c.decodeIfPresent(Bool.self, forKey: .undone) ?? false
    }
}
