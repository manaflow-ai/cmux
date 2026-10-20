/// One summary line of a Chief's memory tree: a node `id+n` covering
/// messages `start ..< start + n`.
public struct ChiefMemoryLine: Sendable, Hashable, Identifiable, Decodable {
    /// The node name, `id+n` (as the agent's `zoom` names it).
    public var name: String
    /// The tree level: 0 for a message's own line, higher for merged lines.
    public var level: Int
    /// The first message it covers.
    public var start: UInt64
    /// How many messages it covers (a power of two).
    public var n: UInt64
    /// Whether its text exists yet.
    public var built: Bool
    /// Its text; nil while it is not built.
    public var text: String?
    /// Waiting to be rebuilt after a change below it.
    public var stale: Bool

    public var id: String { name }

    /// A line; `stale` defaults to false.
    public init(name: String, level: Int, start: UInt64, n: UInt64, built: Bool, text: String?, stale: Bool = false) {
        self.name = name
        self.level = level
        self.start = start
        self.n = n
        self.built = built
        self.text = text
        self.stale = stale
    }

    enum CodingKeys: String, CodingKey { case name, level, start, n, built, text, stale }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        level = try c.decode(Int.self, forKey: .level)
        start = try c.decode(UInt64.self, forKey: .start)
        n = try c.decode(UInt64.self, forKey: .n)
        built = try c.decodeIfPresent(Bool.self, forKey: .built) ?? false
        text = try c.decodeIfPresent(String.self, forKey: .text)
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false
    }
}
