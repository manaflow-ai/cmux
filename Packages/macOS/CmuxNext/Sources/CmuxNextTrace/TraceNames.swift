import CmuxNextCompat

/// The ring's name table (plans/cmux-next/trace.md, "Release trace ring v1", Name table): the fixed catalog
/// and category entries a ring's creator writes, the names interned at run time after them, and the reader
/// that takes every name from the ring's own header. A record stores only a u16 id, and the ring holds the
/// text of each id, so a newer build decodes an older ring whatever order its catalog had. Perfetto keeps
/// interned names per sequence for the same reason (`include/perfetto/tracing/track_event_interned_data_index.h`);
/// Rust's `cmux_trace::decode` reads the same entries.
extension TraceRing {
    /// One published name-table entry.
    public struct NameEntry: Sendable, Equatable {
        /// What an entry names (the entry's `kind` byte).
        public enum Kind: UInt8, Sendable {
            /// A fixed catalog name (`SignpostName`, ids from 1, append-only).
            case catalog = 1
            /// A name interned at run time (``TraceRuntime/InternedName``).
            case interned = 2
            /// A category; its ``NameEntry/category`` is its own bit.
            case category = 3
        }

        /// The id records use.
        public let id: UInt16
        /// The entry's kind byte; ``kind`` reads it.
        public let kindCode: UInt8
        /// The category bit of the name (a category entry: its own bit).
        public let category: UInt8
        /// The name, for example `key.frame`.
        public let text: String

        /// The kind, or nil for a code this build does not know.
        public var kind: Kind? { Kind(rawValue: kindCode) }
    }

    /// The entries a ring's creator writes before any writer sees the ring: each name at its fixed id, then
    /// one entry per category at `last name id + 1 + bit`. Interned names follow from the next id.
    ///
    /// - Parameters:
    ///   - names: the catalog: its id (never 0), its category bit and its text.
    ///   - categories: every category bit and its text.
    /// - Returns: the ``CatalogName`` list for ``init(sizes:identity:catalog:threadIdentity:)``.
    public static func nameTable(names: [(id: UInt16, category: UInt8, text: StaticString)],
                                 categories: [(bit: UInt8, text: StaticString)]) -> [CatalogName] {
        let firstCategoryID = (names.map { $0.id }.max() ?? 0) &+ 1
        let catalog = names.map {
            CatalogName(id: $0.id, kind: NameEntry.Kind.catalog.rawValue, category: $0.category, text: $0.text)
        }
        return catalog + categories.map {
            CatalogName(id: firstCategoryID &+ UInt16($0.bit), kind: NameEntry.Kind.category.rawValue, category: $0.bit,
                        text: $0.text)
        }
    }

    /// Appends one record named by `name`, under its id in the active ring, interned there at its first
    /// record (trace.md "Name table": one id per ring). An id interned in the heap before the file's copy
    /// names the same text in the file, which copies the heap's entries.
    ///
    /// - Parameters:
    ///   - name: the trace point's name; one `static let` per site, serving this process's ring only.
    ///   - phase: begin, end, instant, async, flow or counter.
    ///   - flags: bit 0: `arg1` is an async or track id; bit 1: the time is an estimate.
    ///   - timestamp: trace clock nanoseconds (TraceClock).
    ///   - arg0: the first argument.
    ///   - arg1: the second argument.
    public func write(_ name: TraceRuntime.InternedName, phase: TraceRecord.Phase, flags: UInt8 = 0, timestamp: UInt64,
                      arg0: UInt64 = 0, arg1: UInt64 = 0) {
        guard let active = activeRing else { return }
        write(name: name.id(inSlot: active.pointee.slot, of: active.pointee.storage), phase: phase, flags: flags,
              timestamp: timestamp, arg0: arg0, arg1: arg1)
    }
}

/// A trace point named at run time (p09-observability task 004's `TraceSite`): a `StaticString` and its atomic
/// id per ring, registered into a ring's name table at its first record there.
public typealias TraceSite = TraceRuntime.InternedName

extension TraceRuntime.InternedName {
    /// This name's id in the ring of `slot` (0 heap, 1 black-box file, 2 recording), interned into `storage`
    /// at its first record there. After that it is one relaxed load.
    @inline(__always)
    func id(inSlot slot: Int, of storage: TraceRingStorage) -> UInt16 {
        let known = UInt16(truncatingIfNeeded: ringIDs.load(ordering: .relaxed) >> UInt64(16 * slot))
        return known != 0 ? known : intern(inSlot: slot, of: storage)
    }

    /// Claims an entry in `storage` and keeps its id in the slot's 16 bits, set only while they are 0: when
    /// two threads intern at once, both entries hold the same text and both use the id that won. A full
    /// table gives 0 (counted in `name_overflow`) and caches nothing.
    ///
    /// The exchange is bounded: it fails only when a slot's 16 bits went from 0 to an id, which happens at
    /// most once per slot, so after at most ``ringSlots`` failures it sees its own slot set or stores it.
    @inline(never)
    private func intern(inSlot slot: Int, of storage: TraceRingStorage) -> UInt16 {
        let id = storage.intern(text, category: categoryBit)
        guard id != 0 else { return 0 }
        let shift = UInt64(16 * slot)
        var seen = ringIDs.load(ordering: .relaxed)
        for _ in 0 ... Self.ringSlots {
            let winner = UInt16(truncatingIfNeeded: seen >> shift)
            if winner != 0 { return winner }
            let swap = ringIDs.compareExchange(expected: seen, desired: seen | UInt64(id) << shift, ordering: .relaxed)
            if swap.exchanged { return id }
            seen = swap.original
        }
        return id
    }

    /// The rings a process has (heap, black-box file, recording): the 16-bit slots of ``ringIDs``.
    static let ringSlots = 3
}

extension TraceRingStorage {
    /// The published name entries below `name_cursor`, each read state, text, state again (acquire), and kept
    /// only when both state reads agree.
    func nameEntries() -> [TraceRing.NameEntry] {
        let cursor = Int(word(TraceRingOffsets.nameWord).load(ordering: .acquiring) >> 32)
        let end = min(cursor, layout.nameCapacity)
        guard end > 1 else { return [] }
        var entries: [TraceRing.NameEntry] = []
        for index in 1 ..< end {
            let entry = layout.nameEntry(index)
            let first = word(entry).load(ordering: .acquiring)
            guard first & 0xFFFF_FFFF == TraceRing.entryPublished else { continue }
            // name_len at byte 8, then at most 55 bytes of text: seven words.
            let packed = bytes(at: entry + TraceRingOffsets.entryTextWord, words: 7)
            guard word(entry).load(ordering: .relaxed) == first else { continue }
            let meta = first >> 32
            let length = min(Int(packed[0]), 55)
            entries.append(TraceRing.NameEntry(
                id: UInt16(truncatingIfNeeded: meta), kindCode: UInt8(truncatingIfNeeded: meta >> 16),
                category: UInt8(truncatingIfNeeded: meta >> 24),
                text: String(decoding: packed[1 ..< 1 + length], as: UTF8.self)
            ))
        }
        return entries
    }

    /// `words` aligned words from `offset`, little-endian, as bytes (acquire loads).
    func bytes(at offset: Int, words: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(words * 8)
        for index in 0 ..< words {
            let value = word(offset + index * 8).load(ordering: .acquiring)
            for byte in 0 ..< 8 { out.append(UInt8(truncatingIfNeeded: value >> (8 * UInt64(byte)))) }
        }
        return out
    }
}
