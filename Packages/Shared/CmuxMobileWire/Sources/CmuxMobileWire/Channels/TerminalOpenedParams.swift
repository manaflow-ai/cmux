/// `channel.opened` params of kind `terminal`. A nil `snapshotVersion` means
/// the host falls back to byte replay.
public struct TerminalOpenedParams: Hashable, Sendable, Codable {
    public var generation: UInt32
    public var cols: Int
    public var rows: Int
    public var snapshotVersion: UInt16?
    public var title: String?

    public init(generation: UInt32, cols: Int, rows: Int, snapshotVersion: UInt16?, title: String? = nil) {
        self.generation = generation
        self.cols = cols
        self.rows = rows
        self.snapshotVersion = snapshotVersion
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case generation, cols, rows, title
        case snapshotVersion = "snapshot_version"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generation = try c.decode(UInt32.self, forKey: .generation)
        cols = try c.decode(Int.self, forKey: .cols)
        rows = try c.decode(Int.self, forKey: .rows)
        snapshotVersion = try c.decodeIfPresent(UInt16.self, forKey: .snapshotVersion)
        title = try c.decodeIfPresent(String.self, forKey: .title)
    }

    /// Writes `snapshot_version: null` explicitly (the field is required on the wire).
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(generation, forKey: .generation)
        try c.encode(cols, forKey: .cols)
        try c.encode(rows, forKey: .rows)
        try c.encode(snapshotVersion, forKey: .snapshotVersion)
        try c.encodeIfPresent(title, forKey: .title)
    }
}
