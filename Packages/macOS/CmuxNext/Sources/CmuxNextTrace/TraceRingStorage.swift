import CmuxNextCompat

/// One ring's bytes (a heap block or a mapped file) and the ring v1 operations on them: header and
/// tables, the chunk claim, the record seqlock, the decoder and the copy. The layout is immutable and
/// owned by the caller, so the write path never reads a size or an offset from the shared header (a
/// mapped file another process can write). Every access is an aligned 64-bit atomic, so a reader may
/// run while writers write.
struct TraceRingStorage {
    let base: UnsafeMutableRawPointer
    let layout: TraceRingLayout

    init(base: UnsafeMutableRawPointer, layout: TraceRingLayout) {
        self.base = base
        self.layout = layout
    }

    /// Accepts `base` only when it holds a whole v1 ring of at most `byteCount` bytes; the layout comes
    /// from its header.
    init?(validating base: UnsafeMutableRawPointer, byteCount: Int) {
        guard let layout = TraceRingLayout(header: { Self.word(base, $0).load(ordering: .relaxed) }, byteCount: byteCount)
        else { return nil }
        self.init(base: base, layout: layout)
    }

    /// A zeroed heap block for `layout`. Never freed: a writer may still hold a chunk in it.
    static func allocateHeap(_ layout: TraceRingLayout) -> TraceRingStorage {
        let heap = UnsafeMutableRawPointer.allocate(byteCount: layout.totalBytes, alignment: TraceRing.pageBytes)
        heap.initializeMemory(as: UInt64.self, repeating: 0, count: layout.totalBytes / 8)
        return TraceRingStorage(base: heap, layout: layout)
    }

    @inline(__always)
    static func word(_ pointer: UnsafeMutableRawPointer, _ offset: Int) -> AtomicPointerSlot {
        AtomicPointerSlot((pointer + offset).assumingMemoryBound(to: UInt64.self))
    }

    @inline(__always)
    func word(_ offset: Int) -> AtomicPointerSlot {
        Self.word(base, offset)
    }

    // MARK: - Header and tables

    /// Writes the header, the catalog and the category entries into zeroed storage that no writer sees yet.
    func initialize(identity: TraceRing.Identity, catalog: [TraceRing.CatalogName]) {
        typealias Offsets = TraceRingOffsets
        let put = { (offset: Int, value: UInt64) in word(offset).store(value, ordering: .relaxed) }
        put(Offsets.magic, TraceRing.magic)
        put(Offsets.versionWord, UInt64(TraceRing.version) | UInt64(TraceRing.headerBytes) << 32)
        put(Offsets.identityWord, UInt64(identity.pid) | UInt64(identity.role.rawValue) << 32
            | UInt64(identity.ringKind) << 48 | UInt64(identity.clockDomain) << 56)
        put(Offsets.startUptime, identity.startUptimeNanos)
        put(Offsets.startUnix, identity.startUnixNanos)
        put(Offsets.startContinuous, identity.startContinuousNanos)
        put(Offsets.processStartUnixMicros, identity.processStartUnixMicros)
        putBytes(Offsets.bootSessionUUID, identity.bootSessionUUID, words: 2)
        putBytes(Offsets.buildUUID, identity.buildUUID, words: 2)
        putBytes(Offsets.buildVersion, Array(identity.buildVersion.utf8), words: 4)
        put(Offsets.chunkGeometryWord, UInt64(TraceRing.chunkBytes) | UInt64(layout.chunkCount) << 32)
        put(Offsets.chunksOffset, UInt64(layout.chunksOffset))
        put(Offsets.nameTableOffset, UInt64(layout.nameTableOffset))
        put(Offsets.threadTableOffset, UInt64(layout.threadTableOffset))
        put(Offsets.threadWord, UInt64(layout.threadCapacity))
        put(Offsets.categories, identity.categories)
        var cursor: UInt64 = 1
        for name in catalog {
            guard name.id != 0, Int(name.id) < layout.nameCapacity else {
                word(Offsets.overflowWord).add(1, ordering: .relaxed)
                continue
            }
            writeName(id: name.id, kind: name.kind, category: name.category, text: name.text)
            cursor = max(cursor, UInt64(name.id) + 1)
        }
        put(Offsets.nameWord, UInt64(layout.nameCapacity) | cursor << 32)
    }

    /// Stores `bytes` (zero padded or cut to `words` words) little-endian at `offset`.
    private func putBytes(_ offset: Int, _ bytes: [UInt8], words: Int) {
        for index in 0 ..< words {
            var value: UInt64 = 0
            for byte in 0 ..< 8 where index * 8 + byte < bytes.count {
                value |= UInt64(bytes[index * 8 + byte]) << (8 * UInt64(byte))
            }
            word(offset + index * 8).store(value, ordering: .relaxed)
        }
    }

    private func writeName(id: UInt16, kind: UInt8, category: UInt8, text: StaticString) {
        let entry = layout.nameEntry(Int(id))
        let meta = UInt64(id) | UInt64(kind) << 16 | UInt64(category) << 24
        word(entry).store(meta << 32 | TraceRing.entryWriting, ordering: .relaxed)
        // name_len at byte 8, then at most 55 bytes of text: seven words.
        var packed = [UInt8](repeating: 0, count: 56)
        text.withUTF8Buffer { utf8 in
            var length = min(utf8.count, 55)
            // Cut on a character boundary: never leave a UTF-8 continuation byte first past the cut.
            while length > 0, length < utf8.count, utf8[length] & 0xC0 == 0x80 { length -= 1 }
            packed[0] = UInt8(length)
            for index in 0 ..< length { packed[1 + index] = utf8[index] }
        }
        putBytes(entry + TraceRingOffsets.entryTextWord, packed, words: 7)
        word(entry).store(meta << 32 | TraceRing.entryPublished, ordering: .releasing)
    }

    /// Claims a name entry for `text` and publishes it; 0 (counted in `name_overflow`) when the table is full.
    func intern(_ text: StaticString, category: UInt8) -> UInt16 {
        let nameWord = word(TraceRingOffsets.nameWord)
        let capacity = UInt64(layout.nameCapacity)
        var id = capacity
        if nameWord.load(ordering: .relaxed) >> 32 < capacity {
            id = nameWord.add(1 << 32, ordering: .relaxed).oldValue >> 32
        }
        guard id < capacity else {
            word(TraceRingOffsets.overflowWord).add(1, ordering: .relaxed)
            return 0
        }
        writeName(id: UInt16(id), kind: 2, category: category, text: text)
        return UInt16(id)
    }

    /// Registers a thread (trace.md "Register"): a fresh entry, else an exited one taken again with the
    /// next generation, else ``TraceRing/noThread`` counted in `thread_overflow`.
    func registerThread(tid: UInt64, info: TraceRingThreadInfo) -> (index: UInt32, generation: UInt32) {
        let threadWord = word(TraceRingOffsets.threadWord)
        let capacity = UInt64(layout.threadCapacity)
        if threadWord.load(ordering: .relaxed) >> 32 < capacity {
            let index = threadWord.add(1 << 32, ordering: .relaxed).oldValue >> 32
            if index < capacity {
                let entry = layout.threadEntry(Int(index))
                word(entry).store(TraceRing.entryWriting, ordering: .relaxed)
                fillThread(entry, generation: 0, tid: tid, info: info)
                return (UInt32(index), 0)
            }
        }
        for index in 0 ..< layout.threadCapacity {
            let state = word(layout.threadEntry(index))
            let seen = state.load(ordering: .relaxed)
            guard seen & 0xFFFF_FFFF == TraceRing.threadExited else { continue }
            let generation = UInt32(truncatingIfNeeded: seen >> 32) &+ 1
            let taken = state.compareExchange(expected: seen, desired: UInt64(generation) << 32 | TraceRing.entryWriting,
                                              ordering: .acquiring)
            guard taken.exchanged else { continue }
            fillThread(layout.threadEntry(index), generation: generation, tid: tid, info: info)
            return (UInt32(index), generation)
        }
        word(TraceRingOffsets.overflowWord).add(1 << 32, ordering: .relaxed)
        return (TraceRing.noThread, 0)
    }

    private func fillThread(_ entry: Int, generation: UInt32, tid: UInt64, info: TraceRingThreadInfo) {
        word(entry + TraceRingOffsets.threadTid).store(tid, ordering: .relaxed)
        info.forEachWord { index, value in
            word(entry + TraceRingOffsets.threadInfoWord + index * 8).store(value, ordering: .relaxed)
        }
        word(entry).store(UInt64(generation) << 32 | TraceRing.entryPublished, ordering: .releasing)
    }

    /// Marks a live thread's entry exited (its TLS destructor), so a later thread may take it.
    func exitThread(index: UInt32, generation: UInt32) {
        guard Int(index) < layout.threadCapacity else { return }
        word(layout.threadEntry(Int(index))).store(UInt64(generation) << 32 | TraceRing.threadExited, ordering: .releasing)
    }

    // MARK: - Writing

    /// Claims a chunk for the thread (trace.md "Claim a chunk"): at most four tries, each one
    /// `fetch_add` on the cursor; a try fails on a chunk that is owned (odd `lap_seq`) or claimed by a
    /// newer lap. After four failed tries the record is dropped and counted. Perfetto's producers drop
    /// rather than wait the same way (`BufferExhaustedPolicy::kDrop`).
    @inline(__always)
    func claim(threadIndex: UInt32, generation: UInt32) -> (chunk: Int, lap: UInt64)? {
        let count = UInt64(layout.chunkCount)
        let cursor = word(TraceRingOffsets.chunkCursor)
        // A counted loop, not `for _ in 0 ..< claimTries`: a Debug build runs a range's `IndexingIterator`
        // unspecialized in libswiftCore, whose read coroutine heap-allocates its frame,
        // and a write must not allocate in any build (KeyFrameSignpostAllocationTests).
        var tries = 0
        while tries < TraceRing.claimTries {
            tries += 1
            let ticket = cursor.add(1, ordering: .relaxed).oldValue
            let chunk = Int(ticket & (count - 1))
            let lap = ticket / count
            let lapSeq = word(layout.chunk(chunk) + TraceRingOffsets.chunkLapSeq)
            let seen = lapSeq.load(ordering: .relaxed)
            guard seen & 1 == 0, seen < TraceRingLayout.lapComplete(lap),
                  lapSeq.compareExchange(expected: seen, desired: TraceRingLayout.lapOwned(lap), ordering: .acquiringAndReleasing).exchanged
            else {
                word(TraceRingOffsets.chunksSkipped).add(1, ordering: .relaxed)
                continue
            }
            let startLap = word(TraceRingOffsets.recordingStartCursor).load(ordering: .relaxed) / count
            if seen >= TraceRingLayout.lapComplete(startLap) {
                word(TraceRingOffsets.chunksOverwritten).add(1, ordering: .relaxed)
            }
            // Release stores: a reader that sees the new owner or count also sees the claim before it.
            word(layout.chunk(chunk) + TraceRingOffsets.chunkThreadWord)
                .store(UInt64(threadIndex) | UInt64(generation) << 32, ordering: .releasing)
            word(layout.chunk(chunk) + TraceRingOffsets.chunkPublishedWord).store(0, ordering: .releasing)
            return (chunk, lap)
        }
        word(TraceRingOffsets.recordsDropped).add(1, ordering: .relaxed)
        return nil
    }

    /// Publishes one record in `slot` (1-31) of an owned chunk (trace.md "Publish a record"): the odd
    /// `seq`, the payload, the even `seq` with the name, phase and flags, then `published`. The payload
    /// stores are releases, so a reader that sees any of them also sees the odd `seq` before them (the
    /// spec's release fence).
    @inline(__always)
    func publish(chunk: Int, lap: UInt64, slot: Int, name: UInt16, phase: UInt8, flags: UInt8,
                 timestamp: UInt64, arg0: UInt64, arg1: UInt64) {
        let chunkBase = layout.chunk(chunk)
        let record = chunkBase + slot * TraceRing.recordBytes
        let seqWord = word(record + TraceRingOffsets.recordSeqWord)
        seqWord.store(UInt64(TraceRingLayout.seqWriting(lap)), ordering: .relaxed)
        word(record + TraceRingOffsets.recordTime).store(timestamp, ordering: .releasing)
        word(record + TraceRingOffsets.recordArg0).store(arg0, ordering: .releasing)
        word(record + TraceRingOffsets.recordArg1).store(arg1, ordering: .releasing)
        let meta = UInt64(name) | UInt64(phase) << 16 | UInt64(flags) << 24
        seqWord.store(UInt64(TraceRingLayout.seqPublished(lap)) | meta << 32, ordering: .releasing)
        word(chunkBase + TraceRingOffsets.chunkPublishedWord).store(UInt64(slot), ordering: .releasing)
    }

    /// Completes an owned chunk (`lap_seq = 2*lap+2`). Only the owner stores to an odd `lap_seq`.
    @inline(__always)
    func complete(chunk: Int, lap: UInt64) {
        word(layout.chunk(chunk) + TraceRingOffsets.chunkLapSeq).store(TraceRingLayout.lapComplete(lap), ordering: .releasing)
    }

    func counter(_ offset: Int) -> UInt64 {
        word(offset).load(ordering: .relaxed)
    }

    // MARK: - Decoding

    /// Every whole record of the current recording (lap and time), sorted by time, then claim order and
    /// slot (trace.md "Decode").
    func decode() -> [TraceRecord] {
        var records: [TraceRecord] = []
        let count = UInt64(layout.chunkCount)
        let startLap = word(TraceRingOffsets.recordingStartCursor).load(ordering: .acquiring) / count
        let startTime = word(TraceRingOffsets.startUptime).load(ordering: .relaxed)
        for index in 0 ..< layout.chunkCount {
            let chunkBase = layout.chunk(index)
            let lapSeq = word(chunkBase + TraceRingOffsets.chunkLapSeq)
            let first = lapSeq.load(ordering: .acquiring)
            guard first != 0 else { continue }
            let lap = TraceRingLayout.lap(ofLapSeq: first)
            guard lap >= startLap else { continue }
            let start = records.count
            let wanted = TraceRingLayout.seqPublished(lap)
            for slot in 1 ... TraceRing.recordsPerChunk {
                let record = chunkBase + slot * TraceRing.recordBytes
                guard let payload = readSlot(record), UInt32(truncatingIfNeeded: payload.seqWord) == wanted,
                      payload.time >= startTime else { continue }
                records.append(TraceRecord(
                    timestamp: payload.time, name: UInt16(truncatingIfNeeded: payload.seqWord >> 32),
                    phaseCode: UInt8(truncatingIfNeeded: payload.seqWord >> 48),
                    flags: UInt8(truncatingIfNeeded: payload.seqWord >> 56), arg0: payload.arg0, arg1: payload.arg1,
                    threadIndex: 0, threadGeneration: 0, ticket: lap &* count &+ UInt64(index), slot: slot
                ))
            }
            let thread = word(chunkBase + TraceRingOffsets.chunkThreadWord).load(ordering: .acquiring)
            guard TraceRingLayout.lap(ofLapSeq: lapSeq.load(ordering: .relaxed)) == lap else {
                records.removeSubrange(start...)
                continue
            }
            for position in start ..< records.count {
                records[position].threadIndex = UInt32(truncatingIfNeeded: thread)
                records[position].threadGeneration = UInt32(truncatingIfNeeded: thread >> 32)
            }
        }
        records.sort { ($0.timestamp, $0.ticket, $0.slot) < ($1.timestamp, $1.ticket, $1.slot) }
        return records
    }

    /// The seqlock read of one record: its words when the `seq` word read the same before and after the
    /// payload (acquire loads keep the second read after the payload), else nil.
    @inline(__always)
    private func readSlot(_ record: Int) -> (seqWord: UInt64, time: UInt64, arg0: UInt64, arg1: UInt64)? {
        let seqWord = word(record + TraceRingOffsets.recordSeqWord)
        let first = seqWord.load(ordering: .acquiring)
        let time = word(record + TraceRingOffsets.recordTime).load(ordering: .acquiring)
        let arg0 = word(record + TraceRingOffsets.recordArg0).load(ordering: .acquiring)
        let arg1 = word(record + TraceRingOffsets.recordArg1).load(ordering: .acquiring)
        guard seqWord.load(ordering: .relaxed) == first else { return nil }
        return (first, time, arg0, arg1)
    }

    // MARK: - Copying

    /// Copies this live ring into `destination` (same layout, zeroed, private): the header as it reads
    /// now, every chunk with the decode protocol, then the name and thread entries below the cursors
    /// loaded after the chunks, and those cursors (trace.md "Heap, then file", steps 2 and 3). The chunks
    /// go first: a thread or a name is published before its first record. Returns the copied
    /// `chunk_cursor`.
    @discardableResult
    func copy(into destination: TraceRingStorage) -> UInt64 {
        for offset in stride(from: 0, to: TraceRing.headerBytes, by: 8) {
            destination.word(offset).store(word(offset).load(ordering: .relaxed), ordering: .relaxed)
        }
        for index in 0 ..< layout.chunkCount {
            copyChunk(layout.chunk(index), into: destination)
        }
        let nameWord = word(TraceRingOffsets.nameWord).load(ordering: .acquiring)
        let threadWord = word(TraceRingOffsets.threadWord).load(ordering: .acquiring)
        let cursor = word(TraceRingOffsets.chunkCursor).load(ordering: .acquiring)
        let names = min(Int(nameWord >> 32), layout.nameCapacity)
        if names > 1 {
            for index in 1 ..< names {
                copyEntry(layout.nameEntry(index), into: destination) { $0 == TraceRing.entryPublished }
            }
        }
        // Exited threads too: copied chunks of an exited thread still name it.
        for index in 0 ..< min(Int(threadWord >> 32), layout.threadCapacity) {
            copyEntry(layout.threadEntry(index), into: destination) {
                $0 == TraceRing.entryPublished || $0 == TraceRing.threadExited
            }
        }
        destination.word(TraceRingOffsets.nameWord).store(nameWord, ordering: .relaxed)
        destination.word(TraceRingOffsets.threadWord).store(threadWord, ordering: .relaxed)
        destination.word(TraceRingOffsets.chunkCursor).store(cursor, ordering: .relaxed)
        return cursor
    }

    /// One entry, kept when its first word (state with id or generation) reads the same before and
    /// after the copy and `keep` accepts the state.
    private func copyEntry(_ entry: Int, into destination: TraceRingStorage, keep: (UInt64) -> Bool) {
        let first = word(entry).load(ordering: .acquiring)
        guard keep(first & 0xFFFF_FFFF) else { return }
        var words: [UInt64] = []
        words.reserveCapacity(7)
        for index in 1 ..< TraceRing.entryBytes / 8 {
            words.append(word(entry + index * 8).load(ordering: .acquiring))
        }
        guard word(entry).load(ordering: .relaxed) == first else { return }
        for (index, value) in words.enumerated() {
            destination.word(entry + (index + 1) * 8).store(value, ordering: .relaxed)
        }
        destination.word(entry).store(first, ordering: .releasing)
    }

    /// One chunk with the decode protocol: a slot whose two `seq` reads differ stays zero, a chunk taken
    /// over while it was read keeps `lap_seq` 0, and an odd (owned) `lap_seq` is stored complete: the
    /// copy has no owner, and its published slots are whole.
    private func copyChunk(_ chunkBase: Int, into destination: TraceRingStorage) {
        let first = word(chunkBase + TraceRingOffsets.chunkLapSeq).load(ordering: .acquiring)
        guard first != 0 else { return }
        for slot in 1 ... TraceRing.recordsPerChunk {
            let record = chunkBase + slot * TraceRing.recordBytes
            guard let payload = readSlot(record) else { continue }
            destination.word(record + TraceRingOffsets.recordTime).store(payload.time, ordering: .relaxed)
            destination.word(record + TraceRingOffsets.recordArg0).store(payload.arg0, ordering: .relaxed)
            destination.word(record + TraceRingOffsets.recordArg1).store(payload.arg1, ordering: .relaxed)
            destination.word(record + TraceRingOffsets.recordSeqWord).store(payload.seqWord, ordering: .relaxed)
        }
        let thread = word(chunkBase + TraceRingOffsets.chunkThreadWord).load(ordering: .acquiring)
        let published = word(chunkBase + TraceRingOffsets.chunkPublishedWord).load(ordering: .acquiring)
        let second = word(chunkBase + TraceRingOffsets.chunkLapSeq).load(ordering: .relaxed)
        guard TraceRingLayout.lap(ofLapSeq: second) == TraceRingLayout.lap(ofLapSeq: first) else { return }
        destination.word(chunkBase + TraceRingOffsets.chunkThreadWord).store(thread, ordering: .relaxed)
        destination.word(chunkBase + TraceRingOffsets.chunkPublishedWord).store(published, ordering: .relaxed)
        destination.word(chunkBase + TraceRingOffsets.chunkLapSeq).store(first + (first & 1), ordering: .releasing)
    }

    /// The ring's bytes as a file of it would read: every record whole or absent.
    func snapshot() -> [UInt8] {
        let copy = Self.allocateHeap(layout)
        defer { copy.base.deallocate() }
        self.copy(into: copy)
        return Array(UnsafeRawBufferPointer(start: copy.base, count: layout.totalBytes))
    }
}

/// A thread's `qos`, `name_len` and name, packed as the thread entry's six words at offset 16.
struct TraceRingThreadInfo {
    private var bytes: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0, 0, 0)

    init(qos: UInt8, name: [UInt8]) {
        var packed = [UInt8](repeating: 0, count: 48)
        var length = min(name.count, 46)
        while length > 0, length < name.count, name[length] & 0xC0 == 0x80 { length -= 1 }
        packed[0] = qos
        packed[1] = UInt8(length)
        for index in 0 ..< length { packed[2 + index] = name[index] }
        func word(_ index: Int) -> UInt64 {
            (0 ..< 8).reduce(UInt64(0)) { $0 | UInt64(packed[index * 8 + $1]) << (8 * UInt64($1)) }
        }
        bytes = (word(0), word(1), word(2), word(3), word(4), word(5))
    }

    func forEachWord(_ body: (Int, UInt64) -> Void) {
        body(0, bytes.0)
        body(1, bytes.1)
        body(2, bytes.2)
        body(3, bytes.3)
        body(4, bytes.4)
        body(5, bytes.5)
    }
}
