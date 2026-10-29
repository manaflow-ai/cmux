import Atomics
import Darwin
import Foundation
import Testing
@testable import CmuxNextIPC

// One row of the hand-built table below; the defaults keep its rows short.
private func attrs(
    _ raw: UInt16,
    _ name: String,
    _ priority: MethodPriority,
    ordering: MethodOrdering = .sequence,
    durability: MethodDurability = .replyAfterJournal,
    payload: MethodPayload = .json,
    streamScoped: Bool = false,
    maxBytes: UInt32? = nil,
    coalesce: MethodCoalesce? = nil,
    urgent: Bool = false
) -> MethodAttributes {
    MethodAttributes(id: MethodID(rawValue: raw), name: name, priority: priority, ordering: ordering,
                     durability: durability, payload: payload, streamScoped: streamScoped,
                     crossesStreamOK: nil, maxBytes: maxBytes, coalesce: coalesce, urgent: urgent)
}

private func dense<Entry: Hashable & Sendable>(
    _ families: [MethodTableFamily<Entry>],
    range: ClosedRange<UInt8>
) -> [MethodTableFamily<Entry>?] {
    range.map { id in families.first { $0.id == id } }
}

/// The method tables answer ids and names in O(1), miss everything else, and
/// the generated `MethodTable.schema` agrees with cmux-tui/spec entry by entry.
/// The Rust twin is cmux-ipc's `methods_table_*` tests.
@Suite struct MethodTableTests {
    // A table shaped like cmux-tui/spec/fixtures/ipc-method-tables.
    private static let fixture: MethodTable = {
        let terminalIO = MethodTableFamily(id: 0x01, name: "terminal-io", entries: [
            attrs(0x0100, "send", .input, durability: .memory, streamScoped: true, urgent: true),
            nil,
            attrs(0x0102, "resize-attached-view", .input, durability: .memory, streamScoped: true,
                  coalesce: MethodCoalesce(key: ["view"], additive: [])),
            attrs(0x0103, "scroll-surface", .input, durability: .memory,
                  coalesce: MethodCoalesce(key: ["surface"], additive: ["delta"])),
            attrs(0x0104, "send-binary", .input, durability: .memory, payload: .binary(layoutVersion: 1),
                  streamScoped: true, maxBytes: 65536),
        ])
        let tabs = MethodTableFamily(id: 0x03, name: "tabs", entries: [
            attrs(0x0300, "new-tab", .control, durability: .replyBeforeJournal),
            attrs(0x0301, "list-tabs", .control, ordering: .independent, durability: .readOnly),
            nil,
            attrs(0x0303, "close-tab", .control),
        ])
        let workspace = MethodTableFamily(id: 0x62, name: "workspace", entries: [
            attrs(0x6200, "workspace.list", .background, ordering: .independent, durability: .readOnly),
            nil,
            nil,
            attrs(0x6203, "workspace.read_history", .bulk, ordering: .independent, durability: .readOnly),
        ])
        let terminalEvents = MethodTableFamily(id: 0xC0, name: "terminal-events", entries: [
            EventAttributes(id: EventID(rawValue: 0xC000), name: "output", priority: .bulk, coalesce: nil),
            EventAttributes(id: EventID(rawValue: 0xC001), name: "size-state", priority: .control,
                            coalesce: MethodCoalesce(key: ["surface"], additive: [])),
        ])
        return MethodTable(
            v12: dense([terminalIO, tabs], range: MethodTable.v12FamilyRange),
            v2: dense([workspace], range: MethodTable.v2FamilyRange),
            events: dense([terminalEvents], range: MethodTable.eventFamilyRange)
        )
    }()

    @Test func idLookupsHitTheirEntry() throws {
        let table = Self.fixture
        let send = try #require(table.v12(MethodID(rawValue: 0x0100)))
        #expect(send.name == "send")
        #expect(send.priority == .input && send.urgent && send.streamScoped)
        #expect(table.method(MethodID(rawValue: 0x0100)) == send)
        #expect(MethodPriority.input.rawValue == 0 && MethodPriority.background.rawValue == 3)

        let binary = try #require(table.method(MethodID(rawValue: 0x0104)))
        #expect(binary.payload == .binary(layoutVersion: 1))
        #expect(binary.maxBytes == 65536)

        let history = try #require(table.method(MethodID(rawValue: 0x6203)))
        #expect(history.name == "workspace.read_history")
        #expect(history.priority == .bulk && history.ordering == .independent)
        #expect(table.v2(MethodID(rawValue: 0x6203)) == history)
        #expect(table.event(EventID(rawValue: 0xC001))?.name == "size-state")
    }

    @Test func idLookupsMissFreeOrdinalsAndForeignSpaces() {
        let table = Self.fixture
        // A free ordinal inside a family, an ordinal past its end, an absent
        // family, the edges of the id space, and ids of another space.
        for raw: UInt16 in [0x0101, 0x01FF, 0x0200, 0x0000, 0xFFFF, 0x5F00, 0x6201, 0xC000] {
            #expect(table.v12(MethodID(rawValue: raw)) == nil, "\(MethodID(rawValue: raw))")
        }
        #expect(table.v12(MethodID(rawValue: 0x6200)) == nil)
        #expect(table.v2(MethodID(rawValue: 0x0100)) == nil)
        #expect(table.method(MethodID(rawValue: 0xC000)) == nil)
        #expect(table.event(EventID(rawValue: 0x0100)) == nil)
        #expect(table.event(EventID(rawValue: 0xC002)) == nil)
        #expect(table.event(EventID(rawValue: 0xFF00)) == nil)
    }

    @Test func nameLookupsArePerIDSpace() {
        let table = Self.fixture
        #expect(table.v12ID(named: "close-tab") == MethodID(rawValue: 0x0303))
        #expect(table.v2ID(named: "workspace.list") == MethodID(rawValue: 0x6200))
        #expect(table.eventID(named: "output") == EventID(rawValue: 0xC000))
        #expect(table.v12ID(named: "workspace.list") == nil)
        #expect(table.v2ID(named: "send") == nil)
        #expect(table.eventID(named: "send") == nil)
        #expect(table.v12ID(named: "") == nil)
    }

    /// `methods` lists every command and v2 operation once, in id order, and no event.
    @Test func methodsListsEveryCommandAndOperationInIDOrder() {
        let table = Self.fixture
        let ids = table.methods.map(\.id)
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count)
        #expect(table.methods.contains { $0.name == "close-tab" })
        #expect(table.methods.contains { $0.name == "workspace.list" })
        #expect(!table.methods.contains { $0.name == "output" })
        #expect(table.methods.allSatisfy { table.method($0.id) == $0 })
    }

    /// The app's `debug.daemon.wire` rows take their `id` from `MethodTable.schema.methods` (the
    /// composition root's list), and the daemon's `server-stats` `ipc_methods` rows take theirs from
    /// sdk-schema.json `method_id` (cmux-tui-core `server_stats_ipc_methods_id_is_the_schema_method_id`):
    /// for `identify` and `ping` the two are the same join key.
    @Test func schemaMethodIDsAreTheDaemonsIPCMethodIDs() throws {
        let commands = try #require(try Self.load("sdk-schema.json")["commands"] as? [String: Any])
        for name in ["identify", "ping"] {
            let node = try #require(commands[name] as? [String: Any])
            let schemaID = try #require(node["method_id"] as? Int)
            let appID = try #require(MethodTable.schema.methods.first { $0.name == name }?.id.rawValue)
            #expect(Int(appID) == schemaID, "\(name)")
        }
    }

    @Test func idsSplitIntoFamilyAndOrdinal() {
        let id = MethodID(rawValue: 0x6203)
        #expect(id.family == 0x62 && id.ordinal == 0x03)
        #expect(id.description == "0x6203")
        #expect(EventID(rawValue: 0xC001).description == "0xC001")
        #expect(MethodID(rawValue: 0x0005).description == "0x0005")
    }

    // The generated table agrees with the schema ------------------------------

    private static func load(_ file: String) throws -> [String: Any] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/\(file)"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func coalesce(_ node: [String: Any]) -> MethodCoalesce? {
        guard let spec = node["coalesce"] as? [String: Any] else { return nil }
        return MethodCoalesce(key: spec["key"] as? [String] ?? [], additive: spec["additive"] as? [String] ?? [])
    }

    private static func expectAgrees(_ attrs: MethodAttributes, name: String, node: [String: Any]) {
        #expect(attrs.name == name)
        #expect(attrs.priority.schemaName == node["priority"] as? String, "\(name)")
        #expect(attrs.ordering.schemaName == (node["ordering"] as? String ?? "sequence"), "\(name)")
        // Durability has no default: the table refuses a framed command without one.
        #expect(attrs.durability.schemaName == node["durability"] as? String, "\(name)")
        let payload: MethodPayload = (node["payload"] as? String) == "binary"
            ? .binary(layoutVersion: UInt8(node["layout_version"] as? Int ?? 0)) : .json
        #expect(attrs.payload == payload, "\(name)")
        #expect(attrs.streamScoped == (node["stream_scoped"] as? Bool ?? false), "\(name)")
        #expect(attrs.urgent == (node["urgent"] as? Bool ?? false), "\(name)")
        #expect(attrs.crossesStreamOK == node["crosses_stream_ok"] as? String, "\(name)")
        #expect(attrs.maxBytes.map { Int($0) } == node["max_bytes"] as? Int, "\(name)")
        #expect(attrs.coalesce == coalesce(node), "\(name)")
    }

    private static func expectMethods(
        _ table: MethodTable,
        in doc: [String: Any],
        key: String,
        lookup: (MethodID) -> MethodAttributes?,
        nameLookup: (String) -> MethodID?
    ) throws -> Int {
        var count = 0
        for (name, value) in try #require(doc[key] as? [String: Any]) {
            let node = try #require(value as? [String: Any])
            guard let raw = node["method_id"] as? Int else {
                #expect(nameLookup(name) == nil, "\(name) has no method_id")
                continue
            }
            let id = MethodID(rawValue: try #require(UInt16(exactly: raw)))
            // The app's table holds only what the app calls (absent `clients` is every client).
            if let clients = node["clients"] as? [String], !clients.contains("macos") {
                #expect(lookup(id) == nil, "\(name) has no macos client")
                #expect(nameLookup(name) == nil, "\(name) has no macos client")
                continue
            }
            let attrs = try #require(lookup(id), "\(name): \(id) missing")
            #expect(attrs.id == id)
            #expect(table.method(id) == attrs)
            #expect(nameLookup(name) == id)
            expectAgrees(attrs, name: name, node: node)
            count += 1
        }
        return count
    }

    @Test func schemaTableAgreesWithTheSchema() throws {
        let table = MethodTable.schema
        let sdk = try Self.load("sdk-schema.json")
        let v2 = try Self.load("resource-operations-v2.json")

        let v12Count = try Self.expectMethods(table, in: sdk, key: "commands",
                                              lookup: table.v12, nameLookup: table.v12ID(named:))
        let v2Count = try Self.expectMethods(table, in: v2, key: "operations",
                                             lookup: table.v2, nameLookup: table.v2ID(named:))
        var eventCount = 0
        for (name, value) in try #require(sdk["events"] as? [String: Any]) {
            let node = try #require(value as? [String: Any])
            guard let raw = node["event_id"] as? Int else {
                #expect(table.eventID(named: name) == nil, "\(name) has no event_id")
                continue
            }
            let id = EventID(rawValue: try #require(UInt16(exactly: raw)))
            let attrs = try #require(table.event(id), "\(name): \(id) missing")
            #expect(attrs.name == name && attrs.id == id)
            #expect(attrs.priority.schemaName == node["priority"] as? String, "\(name)")
            #expect(attrs.coalesce == Self.coalesce(node), "\(name)")
            #expect(table.eventID(named: name) == id)
            eventCount += 1
        }

        // The tables hold nothing else, and every family is dense to its last ordinal.
        func held<Entry: Hashable & Sendable>(_ families: [MethodTableFamily<Entry>?]) -> Int {
            families.compactMap { $0 }.reduce(0) { $0 + $1.entries.compactMap { $0 }.count }
        }
        #expect(held(table.v12Families) == v12Count)
        #expect(held(table.v2Families) == v2Count)
        #expect(held(table.eventFamilies) == eventCount)
        #expect(table.v12Families.count == MethodTable.v12FamilyRange.count)
        #expect(table.v2Families.count == MethodTable.v2FamilyRange.count)
        #expect(table.eventFamilies.count == MethodTable.eventFamilyRange.count)
        for family in (table.v12Families + table.v2Families).compactMap({ $0 }) {
            #expect(family.entries.last.flatMap { $0 } != nil, "family \(family.name)")
            for (ordinal, entry) in family.entries.enumerated() {
                guard let entry else { continue }
                #expect(entry.id.family == family.id && Int(entry.id.ordinal) == ordinal)
            }
        }
        for family in table.eventFamilies.compactMap({ $0 }) {
            #expect(family.entries.last.flatMap { $0 } != nil, "family \(family.name)")
            for (ordinal, entry) in family.entries.enumerated() {
                guard let entry else { continue }
                #expect(entry.id.family == family.id && Int(entry.id.ordinal) == ordinal)
            }
        }
    }

    // Lookups do not allocate -------------------------------------------------

    /// Every id of the u16 space through each id lookup, and hit and miss names
    /// through each name lookup, on the generated table and the hand-built one.
    /// Each count is compared with the same loop around a constant, because the
    /// Debug build's loop can allocate by itself (FeatureListTests does the same).
    @Test func lookupsAllocateNothing() throws {
        let tables = [MethodTable.schema, Self.fixture]
        // Names are made before counting; a native String key hashes in place.
        let names = ["send", "close-tab", "workspace.list", "output", "", "no-such-method"]
            + (tables.first?.v12Families.compactMap { $0?.entries.last??.name } ?? [])
        var hits = 0
        func allocations(_ lookup: (MethodTable, UInt16, String) -> Bool) -> Int? {
            MallocProbe.allocations {
                for table in tables {
                    for raw in UInt16.min...UInt16.max where lookup(table, raw, "") { hits += 1 }
                    for name in names where lookup(table, 0, name) { hits += 1 }
                }
            }
        }

        let control = MallocProbe.allocations { hits += ContiguousArray(repeating: 1, count: 64).count }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")
        let baseline = try #require(allocations { _, _, _ in true })

        let ids = allocations { table, raw, _ in
            table.method(MethodID(rawValue: raw)) != nil || table.event(EventID(rawValue: raw)) != nil
        }
        let spaces = allocations { table, raw, _ in
            table.v12(MethodID(rawValue: raw)) != nil || table.v2(MethodID(rawValue: raw)) != nil
        }
        let byName = allocations { table, _, name in
            table.v12ID(named: name) != nil || table.v2ID(named: name) != nil || table.eventID(named: name) != nil
        }
        #expect(ids == baseline, "the loop alone made \(baseline)")
        #expect(spaces == baseline, "the loop alone made \(baseline)")
        #expect(byName == baseline, "the loop alone made \(baseline)")
        #expect(hits > 0)
    }
}

/// Counts the allocations one thread makes, through libmalloc's
/// `malloc_logger` hook (the one malloc stack logging uses), so suites running
/// in parallel on other threads are not counted. Nonisolated: the C hook reads its statics
/// on whatever thread allocates, and this target defaults to the main actor.
nonisolated private struct MallocProbe {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// `MALLOC_LOG_TYPE_ALLOCATE` (libmalloc stack_logging.h).
    static let allocateType: UInt32 = 2
    static let count = ManagedAtomic<Int>(0)
    static let thread = ManagedAtomic<UInt64>(0)

    /// The allocations `body` makes on this thread, or nil when the hook is missing.
    static func allocations(_ body: () -> Void) -> Int? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let slot = symbol.assumingMemoryBound(to: Logger?.self)
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        count.store(0, ordering: .relaxed)
        thread.store(id, ordering: .relaxed)
        let previous = slot.pointee
        slot.pointee = { type, _, _, _, _, _ in
            guard type & MallocProbe.allocateType != 0 else { return }
            var id: UInt64 = 0
            pthread_threadid_np(nil, &id)
            if id == MallocProbe.thread.load(ordering: .relaxed) { MallocProbe.count.wrappingIncrement(ordering: .relaxed) }
        }
        body()
        slot.pointee = previous
        thread.store(0, ordering: .relaxed)
        return count.load(ordering: .relaxed)
    }
}
