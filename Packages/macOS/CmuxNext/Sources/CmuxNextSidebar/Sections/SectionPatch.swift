import Foundation

/// Set or clear an optional field. Absent from a patch = keep.
public nonisolated enum OptionalUpdate<Value: Hashable & Sendable & Codable>: Hashable, Sendable {
    case set(Value)
    case clear

    public var value: Value? {
        if case .set(let value) = self { return value }
        return nil
    }
}

/// Fields `section.update` changes; nil keeps a field.
public nonisolated struct SectionPatch: Hashable, Sendable, Codable {
    public var title: OptionalUpdate<String>?
    public var look: SectionLook?
    public var room: OptionalUpdate<String>?
    public var maxRows: OptionalUpdate<Int>?
    public var showsTitle: Bool?
    /// Arrangement fields, each patched alone so concurrent edits of
    /// different fields (alignment from one window, spacing from another)
    /// both apply.
    public var layout: SectionArrangement.Layout?
    public var align: SectionArrangement.Alignment?
    public var gap: OptionalUpdate<Int>?
    public var columns: OptionalUpdate<Int>?

    public init(title: OptionalUpdate<String>? = nil, look: SectionLook? = nil, room: OptionalUpdate<String>? = nil,
                maxRows: OptionalUpdate<Int>? = nil, showsTitle: Bool? = nil,
                layout: SectionArrangement.Layout? = nil, align: SectionArrangement.Alignment? = nil,
                gap: OptionalUpdate<Int>? = nil, columns: OptionalUpdate<Int>? = nil) {
        self.layout = layout
        self.align = align
        self.gap = gap
        self.columns = columns
        self.showsTitle = showsTitle
        self.title = title
        self.look = look
        self.room = room
        self.maxRows = maxRows
    }

    enum CodingKeys: String, CodingKey {
        case title, look, room
        case maxRows = "max_rows"
        case showsTitle = "shows_title"
        case layout, align, gap, columns
    }

    // Wire: a missing key keeps the field, null clears it, a value sets it.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try Self.decode(String.self, .title, c)
        look = try c.decodeIfPresent(SectionLook.self, forKey: .look)
        room = try Self.decode(String.self, .room, c)
        maxRows = try Self.decode(Int.self, .maxRows, c)
        showsTitle = try c.decodeIfPresent(Bool.self, forKey: .showsTitle)
        layout = try c.decodeIfPresent(SectionArrangement.Layout.self, forKey: .layout)
        align = try c.decodeIfPresent(SectionArrangement.Alignment.self, forKey: .align)
        gap = try Self.decode(Int.self, .gap, c)
        columns = try Self.decode(Int.self, .columns, c)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try Self.encode(title, .title, &c)
        try c.encodeIfPresent(look, forKey: .look)
        try Self.encode(room, .room, &c)
        try Self.encode(maxRows, .maxRows, &c)
        try c.encodeIfPresent(showsTitle, forKey: .showsTitle)
        try c.encodeIfPresent(layout, forKey: .layout)
        try c.encodeIfPresent(align, forKey: .align)
        try Self.encode(gap, .gap, &c)
        try Self.encode(columns, .columns, &c)
    }

    private static func decode<T>(_ type: T.Type, _ key: CodingKeys, _ c: KeyedDecodingContainer<CodingKeys>) throws -> OptionalUpdate<T>? {
        guard c.contains(key) else { return nil }
        if try c.decodeNil(forKey: key) { return .clear }
        return .set(try c.decode(T.self, forKey: key))
    }

    private static func encode<T>(_ update: OptionalUpdate<T>?, _ key: CodingKeys, _ c: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch update {
        case nil: break
        case .clear: try c.encodeNil(forKey: key)
        case .set(let value): try c.encode(value, forKey: key)
        }
    }
}
