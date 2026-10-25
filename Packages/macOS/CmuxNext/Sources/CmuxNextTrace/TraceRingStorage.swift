import CmuxNextCompat

/// A ring's bytes (heap block or mapped file) and the operations on them (layout in ``TraceRing``).
/// Every access is an atomic load or store, so a reader may run while writers write.
struct TraceRingStorage {
    let base: UnsafeMutableRawPointer

    init(_ base: UnsafeMutableRawPointer) {
        self.base = base
    }

    init?(address: UInt) {
        guard let base = UnsafeMutableRawPointer(bitPattern: address) else { return nil }
        self.base = base
    }

    /// Accepts `base` only when it holds a whole v1 ring of at most `byteCount` bytes.
    init?(validating base: UnsafeMutableRawPointer, byteCount: Int) {
        guard byteCount >= TraceRing.headerBytes else { return nil }
        let storage = TraceRingStorage(base)
        guard Self.word(base, Self.headerMagic).load(ordering: .relaxed) == Self.magic,
              UInt32(truncatingIfNeeded: Self.word(base, Self.headerVersion).load(ordering: .relaxed)) == TraceRing.version,
              Self.word(base, Self.headerChunkOffset).load(ordering: .relaxed) == UInt64(TraceRing.headerBytes),
              storage.chunkCount > 0, storage.chunkCount <= byteCount / TraceRing.chunkBytes,
              storage.byteCount <= byteCount else { return nil }
        self = storage
    }

    // Header offsets.
    static let headerMagic = 0
    static let headerVersion = 8
    static let headerPid = 16
    static let headerChunkCount = 24
    static let headerChunkOffset = 32
    static let headerStartUptime = 40
    static let headerRole = 64
    /// Word 112: 1 when the storage is a mapped file.
    static let headerFileBacked = 112
    static let headerCursor = 256
    static let headerOverwritten = 384
    static let headerSkipped = 392
    static let headerDropped = 400
    /// "CMXTRACE" as a little-endian u64.
    static let magic: UInt64 = 0x4543_4152_5458_4D43

    // Chunk header offsets.
    static let chunkThread = 0
    static let chunkLap = 8
    static let chunkPublished = 16
    static let ownedBit: UInt64 = 1 << 63
    static let lapMask: UInt64 = ~ownedBit

    @inline(__always)
    static func word(_ pointer: UnsafeMutableRawPointer, _ offset: Int) -> AtomicPointerSlot {
        AtomicPointerSlot((pointer + offset).assumingMemoryBound(to: UInt64.self))
    }

    var chunkCount: Int {
        Int(truncatingIfNeeded: Self.word(base, Self.headerChunkCount).load(ordering: .relaxed))
    }

    var byteCount: Int {
        TraceRing.storageBytes(chunkCount: chunkCount)
    }

    @inline(__always)
    func chunk(_ index: Int) -> UnsafeMutableRawPointer {
        base + TraceRing.headerBytes + index * TraceRing.chunkBytes
    }

    /// Whether `chunk` is one of this storage's chunks.
    @inline(__always)
    func contains(_ chunk: UnsafeMutableRawPointer) -> Bool {
        let offset = UInt(bitPattern: chunk) &- UInt(bitPattern: base) &- UInt(TraceRing.headerBytes)
        return offset < UInt(chunkCount * TraceRing.chunkBytes)
    }

    /// Writes a fresh header into zeroed storage.
    func writeHeader(chunkCount: Int, role: String, pid: Int32, startUptimeNanos: UInt64, fileBacked: Bool) {
        Self.word(base, Self.headerMagic).store(Self.magic, ordering: .relaxed)
        Self.word(base, Self.headerVersion).store(UInt64(TraceRing.version) | UInt64(TraceRing.headerBytes) << 32, ordering: .relaxed)
        Self.word(base, Self.headerPid).store(UInt64(UInt32(bitPattern: pid)) | UInt64(TraceRing.chunkBytes) << 32, ordering: .relaxed)
        Self.word(base, Self.headerChunkCount).store(UInt64(chunkCount), ordering: .relaxed)
        Self.word(base, Self.headerChunkOffset).store(UInt64(TraceRing.headerBytes), ordering: .relaxed)
        Self.word(base, Self.headerStartUptime).store(startUptimeNanos, ordering: .relaxed)
        var roleWords: [UInt64] = [0, 0]
        for (index, byte) in role.utf8.prefix(16).enumerated() {
            roleWords[index / 8] |= UInt64(byte) << (8 * (index % 8))
        }
        Self.word(base, Self.headerRole).store(roleWords[0], ordering: .relaxed)
        Self.word(base, Self.headerRole + 8).store(roleWords[1], ordering: .relaxed)
        Self.word(base, Self.headerFileBacked).store(fileBacked ? 1 : 0, ordering: .relaxed)
    }

    /// The header's start uptime.
    var startUptimeNanos: UInt64 {
        Self.word(base, Self.headerStartUptime).load(ordering: .relaxed)
    }

    var isFileBacked: Bool {
        Self.word(base, Self.headerFileBacked).load(ordering: .relaxed) != 0
    }

    func counter(_ offset: Int) -> UInt64 {
        Self.word(base, offset).load(ordering: .relaxed)
    }

    /// Claims the oldest chunk no live writer owns, for a writer with `threadWord`. Nil, and a counted
    /// drop, after one full lap of owned chunks.
    func acquireChunk(threadWord: UInt64) -> UnsafeMutableRawPointer? {
        let count = UInt64(chunkCount)
        let cursor = Self.word(base, Self.headerCursor)
        for _ in 0 ..< count {
            let ticket = cursor.add(1, ordering: .relaxed).oldValue
            let chunk = chunk(Int(ticket % count))
            let lap = ticket / count
            let lapWord = Self.word(chunk, Self.chunkLap)
            let current = lapWord.load(ordering: .relaxed)
            if current & Self.ownedBit != 0 {
                Self.word(base, Self.headerSkipped).add(1, ordering: .relaxed)
                continue
            }
            // A later ticket already took this chunk: never move its lap back.
            if current != 0, current &- 1 >= lap { continue }
            let claimed = lapWord.compareExchange(expected: current, desired: Self.ownedBit | (lap + 1), ordering: .acquiringAndReleasing)
            guard claimed.exchanged else { continue }
            if current != 0 {
                Self.word(base, Self.headerOverwritten).add(1, ordering: .relaxed)
            }
            Self.word(chunk, Self.chunkPublished).store(0, ordering: .relaxed)
            Self.word(chunk, Self.chunkThread).store(threadWord, ordering: .releasing)
            return chunk
        }
        Self.word(base, Self.headerDropped).add(1, ordering: .relaxed)
        return nil
    }

    /// The lap of a chunk the caller owns.
    @inline(__always)
    static func lap(ofOwned chunk: UnsafeMutableRawPointer) -> UInt64 {
        (word(chunk, chunkLap).load(ordering: .relaxed) & lapMask) &- 1
    }

    /// Lets other writers claim `chunk` again. Only its owner calls this (or the thread-exit destructor):
    /// no claimer writes the lap word of an owned chunk.
    static func releaseChunk(_ chunk: UnsafeMutableRawPointer) {
        let lapWord = word(chunk, chunkLap)
        lapWord.store(lapWord.load(ordering: .relaxed) & lapMask, ordering: .releasing)
    }

    /// Writes one record with the seqlock: odd sequence, payload, even sequence, then the published
    /// count. The payload stores are releases, so a reader that sees any of them also sees the odd
    /// sequence stored before them, and rejects the slot when it reads the sequence again.
    @inline(__always)
    static func publish(chunk: UnsafeMutableRawPointer, slot: Int, lap: UInt64, name: UInt16, phase: UInt8,
                        flags: UInt8, timestamp: UInt64, arg0: UInt64, arg1: UInt64) {
        let record = chunk + slot * TraceRing.recordBytes
        let sequence = UInt64(UInt32(truncatingIfNeeded: lap &* 2 &+ 1))
        let header = word(record, 8)
        header.store(sequence, ordering: .relaxed)
        word(record, 0).store(timestamp, ordering: .releasing)
        word(record, 16).store(arg0, ordering: .releasing)
        word(record, 24).store(arg1, ordering: .releasing)
        let even = UInt64(UInt32(truncatingIfNeeded: sequence &+ 1))
        header.store(even | UInt64(name) << 32 | UInt64(phase) << 48 | UInt64(flags) << 56, ordering: .releasing)
        word(chunk, chunkPublished).store(UInt64(slot), ordering: .releasing)
    }

    /// Every whole record, sorted by time, then by write order (ticket, slot).
    func decode() -> [TraceRecord] {
        var records: [TraceRecord] = []
        let count = chunkCount
        for index in 0 ..< count {
            decodeChunk(index, chunkCount: count, into: &records)
        }
        records.sort { ($0.timestamp, $0.ticket, $0.slot) < ($1.timestamp, $1.ticket, $1.slot) }
        return records
    }

    /// Appends the chunk's whole records of its current lap; none when the chunk changed lap meanwhile.
    private func decodeChunk(_ index: Int, chunkCount: Int, into records: inout [TraceRecord]) {
        let chunk = chunk(index)
        let lapWord = Self.word(chunk, Self.chunkLap)
        let before = lapWord.load(ordering: .acquiring) & Self.lapMask
        guard before != 0 else { return }
        let lap = before - 1
        let wanted = UInt32(truncatingIfNeeded: lap &* 2 &+ 2)
        let published = min(Int(truncatingIfNeeded: Self.word(chunk, Self.chunkPublished).load(ordering: .acquiring)), TraceRing.recordsPerChunk)
        guard published > 0 else { return }
        let start = records.count
        for slot in 1 ... published {
            let record = chunk + slot * TraceRing.recordBytes
            let header = Self.word(record, 8)
            let first = header.load(ordering: .acquiring)
            guard UInt32(truncatingIfNeeded: first) == wanted else { continue }
            let timestamp = Self.word(record, 0).load(ordering: .acquiring)
            let arg0 = Self.word(record, 16).load(ordering: .acquiring)
            let arg1 = Self.word(record, 24).load(ordering: .acquiring)
            guard header.load(ordering: .relaxed) == first else { continue }
            records.append(TraceRecord(
                timestamp: timestamp, name: UInt16(truncatingIfNeeded: first >> 32),
                phaseCode: UInt8(truncatingIfNeeded: first >> 48), flags: UInt8(truncatingIfNeeded: first >> 56),
                arg0: arg0, arg1: arg1, threadIndex: 0, threadGeneration: 0,
                ticket: lap &* UInt64(chunkCount) &+ UInt64(index), slot: slot
            ))
        }
        let thread = Self.word(chunk, Self.chunkThread).load(ordering: .acquiring)
        guard lapWord.load(ordering: .relaxed) & Self.lapMask == before else {
            records.removeSubrange(start...)
            return
        }
        for position in start ..< records.count {
            records[position].threadIndex = UInt32(truncatingIfNeeded: thread)
            records[position].threadGeneration = UInt32(truncatingIfNeeded: thread >> 32)
        }
    }

    /// Copies every whole record of `source` into this storage, one claimed chunk per source chunk, in
    /// write order, keeping each chunk's thread word. Safe while writers write here.
    func copyRecords(from source: TraceRingStorage) {
        let byChunk = Dictionary(grouping: source.decode(), by: \.ticket)
        for ticket in byChunk.keys.sorted() {
            guard let records = byChunk[ticket]?.sorted(by: { $0.slot < $1.slot }), let first = records.first else { continue }
            let threadWord = UInt64(first.threadIndex) | UInt64(first.threadGeneration) << 32
            guard let chunk = acquireChunk(threadWord: threadWord) else { return }
            let lap = Self.lap(ofOwned: chunk)
            for (offset, record) in records.enumerated() {
                Self.publish(chunk: chunk, slot: offset + 1, lap: lap, name: record.name, phase: record.phaseCode,
                             flags: record.flags, timestamp: record.timestamp, arg0: record.arg0, arg1: record.arg1)
            }
            Self.releaseChunk(chunk)
        }
    }

    /// Adds `source`'s loss counters to this storage's.
    func addCounters(from source: TraceRingStorage) {
        for offset in [Self.headerOverwritten, Self.headerSkipped, Self.headerDropped] {
            Self.word(base, offset).add(source.counter(offset), ordering: .relaxed)
        }
    }
}
