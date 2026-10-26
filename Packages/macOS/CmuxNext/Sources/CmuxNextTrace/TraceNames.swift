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
    /// record (trace.md "Name table": one id per ring). After that first record the name costs one relaxed
    /// load on top of ``write(name:phase:flags:timestamp:arg0:arg1:)``. The active ring is loaded once: the
    /// id and the record are in the same ring also when an adoption swaps it meanwhile.
    ///
    /// - Parameters:
    ///   - name: the trace point's name; one `static let` per site.
    ///   - phase: begin, end, instant, async, flow or counter.
    ///   - flags: bit 0: `arg1` is an async or track id; bit 1: the time is an estimate.
    ///   - timestamp: trace clock nanoseconds (TraceClock).
    ///   - arg0: the first argument.
    ///   - arg1: the second argument.
    // perf-hot: 60ns trace-ring-write-interned
    public func write(_ name: TraceRuntime.InternedName, phase: TraceRecord.Phase, flags: UInt8 = 0, timestamp: UInt64,
                      arg0: UInt64 = 0, arg1: UInt64 = 0) {
        guard let active = activeRing else { return }
        write(into: active, name: name.id(inSlot: active.pointee.slot, of: active.pointee.storage), phase: phase,
              flags: flags, timestamp: timestamp, arg0: arg0, arg1: arg1)
    }
}

/// A trace point named at run time (p09-observability task 004's `TraceSite`): a `StaticString` and its atomic
/// id per ring, registered into a ring's name table at its first record there.
public typealias TraceSite = TraceRuntime.InternedName

extension TraceRuntime.InternedName {
    /// This name's id in `storage`, the ring of `slot` (0 heap, 1 black-box file, 2 recording), interned
    /// there at its first record. After that it is one relaxed load and a compare of the ring's tag.
    // perf-hot: 60ns trace-ring-write-interned
    @inline(__always)
    func id(inSlot slot: Int, of storage: TraceRingStorage) -> UInt16 {
        let tag = Self.tag(of: storage)
        let known = cached(slot)
        return known & ~Self.idMask == tag ? UInt16(truncatingIfNeeded: known) : intern(inSlot: slot, of: storage, tag: tag)
    }

    /// The id cached for `slot`, 0 when none: tests and tools only (it does not say which ring gave it).
    func cachedID(inSlot slot: Int) -> UInt16 {
        UInt16(truncatingIfNeeded: cached(slot))
    }

    /// Claims an entry in `storage` and caches its id with the ring's tag. When two threads intern into one
    /// ring at once, both entries hold the same text and the record uses the id that won. A word holding
    /// another ring's tag is taken over, so each ring's records name only its own entries. A full table
    /// gives 0 (counted in `name_overflow`) and caches nothing.
    ///
    /// The exchange is bounded: after ``cacheTries`` lost exchanges (rings in one slot taking the word in
    /// turn) the record uses its own entry's id, which is valid in `storage`, and leaves the cache alone.
    @inline(never)
    private func intern(inSlot slot: Int, of storage: TraceRingStorage, tag: UInt64) -> UInt16 {
        let id = storage.intern(text, category: categoryBit)
        guard id != 0 else { return 0 }
        var seen = cached(slot)
        for _ in 0 ..< Self.cacheTries {
            if seen & ~Self.idMask == tag { return UInt16(truncatingIfNeeded: seen) }
            let swap = exchange(slot, expected: seen, desired: tag | UInt64(id))
            if swap.exchanged { return id }
            seen = swap.original
        }
        return id
    }

    /// The tag of a ring: its storage's address above bit 12 (every ring is page aligned, and no storage
    /// is ever freed or unmapped, so no two rings of a process share one), shifted past the 16-bit id.
    @inline(__always)
    private static func tag(of storage: TraceRingStorage) -> UInt64 {
        (UInt64(UInt(bitPattern: storage.base)) >> 12) << 16
    }

    @inline(__always)
    private func cached(_ slot: Int) -> UInt64 {
        switch slot {
        case TraceRingActive.heapSlot: heapID.load(ordering: .relaxed)
        case TraceRingActive.fileSlot: fileID.load(ordering: .relaxed)
        default: recordingID.load(ordering: .relaxed)
        }
    }

    private func exchange(_ slot: Int, expected: UInt64, desired: UInt64) -> (exchanged: Bool, original: UInt64) {
        switch slot {
        case TraceRingActive.heapSlot: heapID.compareExchange(expected: expected, desired: desired, ordering: .relaxed)
        case TraceRingActive.fileSlot: fileID.compareExchange(expected: expected, desired: desired, ordering: .relaxed)
        default: recordingID.compareExchange(expected: expected, desired: desired, ordering: .relaxed)
        }
    }

    /// The id bits of a cache word.
    private static let idMask: UInt64 = 0xFFFF
    /// Exchanges an intern tries before it uses its own entry uncached.
    private static let cacheTries = 4
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
