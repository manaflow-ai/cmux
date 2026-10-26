// The schema's method tables: what the framed transport knows about a method
// without parsing its payload (plans/cmux-next/chrome-parity/p05-ipc.md,
// section 3.3; cmux-tui/spec/transports.md, "Framed IPC method attributes").
//
// The Rust twin is cmux-tui/crates/cmux-ipc/src/methods.rs. Both follow Mojo,
// which scopes message ordinals per interface and dispatches on them through
// generated tables (mojo/public/tools/bindings/generators/cpp_templates/
// interface_stub_declaration.tmpl). A wire id is `family << 8 | ordinal`; each
// id space (v12 commands, resource-operations-v2 operations, events) is a dense
// array of families, each a dense array of ordinals. An id lookup is two
// bounds-checked indexes and a name lookup is one hash probe; neither allocates.
//
// The data comes from CmuxNextWireGen's TableEmitter at build time: it writes
// `MethodTable+Schema.swift` (the `schema` table) into the plugin work
// directory. Nothing generated is committed.

/// One family: its entries indexed by ordinal (nil is a free ordinal).
public struct MethodTableFamily<Entry: Hashable & Sendable>: Hashable, Sendable {
    public let id: UInt8
    /// The schema's kebab-case family name.
    public let name: String
    public let entries: [Entry?]

    public init(id: UInt8, name: String, entries: [Entry?]) {
        self.id = id
        self.name = name
        self.entries = entries
    }

    /// The entry at `ordinal`, if one holds it.
    public func entry(at ordinal: UInt8) -> Entry? {
        let index = Int(ordinal)
        return index < entries.count ? entries[index] : nil
    }
}

/// Every framed method and event of one schema build. The app builds one at
/// its composition root (`MethodTable.schema`) and injects it.
public struct MethodTable: Sendable {
    /// Family ranges of each id space.
    public static let v12FamilyRange: ClosedRange<UInt8> = 0x01...0x5F
    public static let v2FamilyRange: ClosedRange<UInt8> = 0x60...0xBF
    public static let eventFamilyRange: ClosedRange<UInt8> = 0xC0...0xFE

    /// Indexed by `family - range.lowerBound`.
    public let v12Families: [MethodTableFamily<MethodAttributes>?]
    public let v2Families: [MethodTableFamily<MethodAttributes>?]
    public let eventFamilies: [MethodTableFamily<EventAttributes>?]
    private let v12Names: [String: MethodID]
    private let v2Names: [String: MethodID]
    private let eventNames: [String: EventID]

    /// Builds the name indexes once. Each array is the dense family array of
    /// its id space, indexed by `family - range.lowerBound` (nil is a free
    /// family); the generated `schema` passes them in that shape.
    public init(
        v12: [MethodTableFamily<MethodAttributes>?],
        v2: [MethodTableFamily<MethodAttributes>?],
        events: [MethodTableFamily<EventAttributes>?]
    ) {
        v12Families = v12
        v2Families = v2
        eventFamilies = events
        v12Names = Self.names(v12, id: \.id, name: \.name)
        v2Names = Self.names(v2, id: \.id, name: \.name)
        eventNames = Self.names(events, id: \.id, name: \.name)
    }

    /// Every v12 command, then every v2 operation, in id order.
    public var methods: [MethodAttributes] {
        (v12Families + v2Families).flatMap { $0?.entries ?? [] }.compactMap { $0 }
    }

    /// The command or v2 operation with `id`, by its family range.
    public func method(_ id: MethodID) -> MethodAttributes? {
        v12(id) ?? v2(id)
    }

    /// The v12 command with `id`.
    public func v12(_ id: MethodID) -> MethodAttributes? {
        Self.entry(v12Families, range: Self.v12FamilyRange, family: id.family, ordinal: id.ordinal)
    }

    /// The resource-operations-v2 operation with `id`.
    public func v2(_ id: MethodID) -> MethodAttributes? {
        Self.entry(v2Families, range: Self.v2FamilyRange, family: id.family, ordinal: id.ordinal)
    }

    /// The event with `id`.
    public func event(_ id: EventID) -> EventAttributes? {
        Self.entry(eventFamilies, range: Self.eventFamilyRange, family: id.family, ordinal: id.ordinal)
    }

    /// The id of the v12 command named `name` (a line's `cmd`).
    public func v12ID(named name: String) -> MethodID? { v12Names[name] }

    /// The id of the v2 operation named `name` (an envelope's `operation`).
    public func v2ID(named name: String) -> MethodID? { v2Names[name] }

    /// The id of the event named `name`.
    public func eventID(named name: String) -> EventID? { eventNames[name] }

    private static func entry<Entry: Hashable & Sendable>(
        _ families: [MethodTableFamily<Entry>?],
        range: ClosedRange<UInt8>,
        family: UInt8,
        ordinal: UInt8
    ) -> Entry? {
        guard range.contains(family) else { return nil }
        let index = Int(family - range.lowerBound)
        guard index < families.count, let table = families[index] else { return nil }
        return table.entry(at: ordinal)
    }

    private static func names<Entry: Hashable & Sendable, ID>(
        _ families: [MethodTableFamily<Entry>?],
        id: KeyPath<Entry, ID>,
        name: KeyPath<Entry, String>
    ) -> [String: ID] {
        var out: [String: ID] = [:]
        for family in families {
            for entry in family?.entries ?? [] {
                if let entry { out[entry[keyPath: name]] = entry[keyPath: id] }
            }
        }
        return out
    }

    static func hex(_ raw: UInt16) -> String {
        let digits = String(raw, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }
}
