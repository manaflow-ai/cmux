import CmuxNextCompat
import Darwin

/// One process's trace ring v1, written byte for byte as plans/cmux-next/trace.md "Release trace ring
/// v1" specifies (the Rust `cmux-trace` crate and the C writer write the same bytes; the shared golden
/// file `Tests/CmuxNextTraceTests/Fixtures/ring-v1-golden.cmxtrace` pins them): 32-byte records in
/// 1 KiB chunks, each chunk owned by one writing thread, so threads never contend on a record.
///
/// This is Perfetto's shared memory buffer (`src/tracing/core/shared_memory_abi.h`): a writer owns its
/// chunk until slot 31, then claims the next with one `fetch_add` on the chunk cursor and one
/// compare-and-swap of the chunk's `lap_seq`. A claim skips a chunk another writer still owns and gives up
/// after four tries (Perfetto's `BufferExhaustedPolicy::kDrop`). Unlike Perfetto there is no consumer:
/// when the cursor wraps, a claim overwrites the oldest chunk (black-box semantics) and counts it.
///
/// The ring starts on the heap. ``TraceRingFile/adopt(_:directory:)`` copies it into a `MAP_SHARED` file
/// off main and then swaps the active ring. No storage is ever freed or unmapped, so a writer that still
/// holds an old chunk never faults; the ring lives as long as the process, like Chrome's `TraceLog`.
public final class TraceRing: Sendable {
    /// The header's process fields.
    public let identity: Identity

    /// The address of the active ring's ``TraceRingActive`` (never freed): the heap ring, then the file.
    private let activeCell = Atomic<UInt64>(0)
    /// The calling thread's ``TraceRingThreadState``; its destructor completes the thread's chunk and
    /// marks its thread entries exited.
    private let threadKey: pthread_key_t
    private let hasThreadKey: Bool
    private let threadIdentity: @Sendable () -> ThreadIdentity
    /// 0 heap, 1 adopting, 2 file-backed: adoption is one-shot.
    private let adoption = Atomic<UInt64>(0)
    private let adoptFailureCount = Atomic<UInt64>(0)

    /// Makes a heap ring. Its memory is never freed (a thread may hold a chunk in it until that thread
    /// exits), so a process makes one ring per use, for its lifetime.
    ///
    /// - Parameters:
    ///   - sizes: the tables and chunks (trace.md "Sizes by role" for a real process).
    ///   - identity: the header's process fields.
    ///   - catalog: the fixed names and categories, written before any writer sees the ring.
    ///   - threadIdentity: reads the calling thread's tid, QoS and name, once per thread (tests inject it).
    public init(sizes: Sizes, identity: Identity, catalog: [CatalogName] = [],
                threadIdentity: @escaping @Sendable () -> ThreadIdentity = ThreadIdentity.current) {
        self.identity = identity
        self.threadIdentity = threadIdentity
        var key = pthread_key_t()
        hasThreadKey = pthread_key_create(&key) { TraceRingThreadState.threadExited($0) } == 0
        threadKey = key
        let heap = TraceRingStorage.allocateHeap(TraceRingLayout(sizes))
        heap.initialize(identity: identity, catalog: catalog)
        activeCell.store(UInt64(UInt(bitPattern: TraceRingActive.make(heap, slot: TraceRingActive.heapSlot))), ordering: .releasing)
    }

    /// A heap ring with room for `records` records and small tables (tests and tools); `pid` nil is this
    /// process.
    public convenience init(records: Int, role: Role, pid: UInt32? = nil) {
        self.init(sizes: Sizes(records: records), identity: Identity(pid: pid ?? UInt32(bitPattern: getpid()), role: role))
    }

    /// Appends one record to the active ring. Lock-free, and after the thread's first write (which
    /// allocates the thread's state and reads its tid, QoS and name once) no allocation, system call or
    /// Foundation call: a `pthread_getspecific`, an acquire load of the active ring and the record's
    /// stores. Every 31st write also claims a chunk; when four claim tries find owned chunks, the record is
    /// dropped and counted.
    ///
    /// One write at a time per thread: a signal handler must not write (it would share the slot of the
    /// write it interrupted), and a forked child must not write (its thread state names the parent's
    /// chunks, which a `MAP_SHARED` file shares with the parent).
    ///
    /// - Parameters:
    ///   - name: the name id in the active ring's name table.
    ///   - phase: begin, end, instant, async, flow or counter.
    ///   - flags: bit 0: `arg1` is an async or track id; bit 1: the time is an estimate.
    ///   - timestamp: trace clock nanoseconds (TraceClock).
    ///   - arg0: the first argument.
    ///   - arg1: the second argument.
    // perf-hot: 60ns trace-ring-write
    public func write(name: UInt16, phase: TraceRecord.Phase, flags: UInt8 = 0, timestamp: UInt64,
                      arg0: UInt64 = 0, arg1: UInt64 = 0) {
        guard let active = activeRing else { return }
        write(into: active, name: name, phase: phase, flags: flags, timestamp: timestamp, arg0: arg0, arg1: arg1)
    }

    /// Appends one record to `active`, the ring the caller loaded once: a name id resolved in that ring
    /// (TraceNames.swift) goes into the same ring's record even when an adoption swaps the active ring
    /// between the two (trace.md "Name table": ids never cross rings; Rust's `Tracer::write` the same).
    @inline(__always)
    func write(into active: UnsafeMutablePointer<TraceRingActive>, name: UInt16, phase: TraceRecord.Phase, flags: UInt8,
               timestamp: UInt64, arg0: UInt64, arg1: UInt64) {
        guard hasThreadKey, let state = threadState() else { return }
        if state.pointee.nextSlot != 0, let owner = state.pointee.owner, owner != active {
            // The active ring changed: complete the chunk in the old one, claim in the new one.
            owner.pointee.storage.complete(chunk: state.pointee.chunk, lap: state.pointee.lap)
            state.pointee.nextSlot = 0
        }
        let storage = active.pointee.storage
        if state.pointee.nextSlot == 0 {
            let thread = TraceRingThreadState.entry(state, in: active)
            guard let claimed = storage.claim(threadIndex: thread.index, generation: thread.generation) else { return }
            state.pointee.owner = active
            state.pointee.chunk = claimed.chunk
            state.pointee.lap = claimed.lap
            state.pointee.nextSlot = 1
        }
        let slot = state.pointee.nextSlot
        storage.publish(chunk: state.pointee.chunk, lap: state.pointee.lap, slot: slot, name: name, phase: phase.rawValue,
                        flags: flags, timestamp: timestamp, arg0: arg0, arg1: arg1)
        if slot == Self.recordsPerChunk {
            storage.complete(chunk: state.pointee.chunk, lap: state.pointee.lap)
            state.pointee.nextSlot = 0
        } else {
            state.pointee.nextSlot = slot + 1
        }
    }

    /// Registers `text` in the active ring's name table and returns its id there, or 0 (counted in
    /// `name_overflow`) when the table is full. The id is valid in the active ring only: task 004's trace
    /// sites keep one id per ring.
    public func intern(_ text: StaticString, category: UInt8) -> UInt16 {
        activeRing?.pointee.storage.intern(text, category: category) ?? 0
    }

    /// The whole records in the active ring, oldest first (by time, then by write order). Safe while
    /// threads write: a record being written or overwritten is left out.
    public func records() -> [TraceRecord] {
        activeRing?.pointee.storage.decode() ?? []
    }

    /// The active ring's bytes as a file of it would read (every record whole or absent), safe while
    /// threads write. ``records(inImage:)`` decodes it.
    public func image() -> [UInt8] {
        activeRing?.pointee.storage.snapshot() ?? []
    }

    /// Decodes a ring image (``image()`` or a ring file's bytes); nil when it is not a whole v1 ring.
    public static func records(inImage bytes: [UInt8]) -> [TraceRecord]? {
        TraceRingStorage.withValidated(bytes: bytes) { $0.decode() }
    }

    /// Whether writes go to a mapped file rather than the heap.
    public var isFileBacked: Bool {
        activeRing?.pointee.slot == TraceRingActive.fileSlot
    }

    /// The records the active ring holds when full.
    public var capacity: Int {
        (activeRing?.pointee.storage.layout.chunkCount ?? 0) * Self.recordsPerChunk
    }

    /// What the active ring lost or skipped so far (its header counters).
    public var counters: Counters {
        let storage = activeRing?.pointee.storage
        let overflow = storage?.counter(TraceRingOffsets.overflowWord) ?? 0
        return Counters(
            chunksOverwritten: storage?.counter(TraceRingOffsets.chunksOverwritten) ?? 0,
            chunksSkipped: storage?.counter(TraceRingOffsets.chunksSkipped) ?? 0,
            recordsDropped: storage?.counter(TraceRingOffsets.recordsDropped) ?? 0,
            nameOverflow: overflow & 0xFFFF_FFFF,
            threadOverflow: overflow >> 32,
            heapChunksLost: (storage?.counter(TraceRingOffsets.heapChunksLostWord) ?? 0) & 0xFFFF_FFFF,
            adoptFailures: adoptFailureCount.load(ordering: .relaxed)
        )
    }

    /// What a ring lost or skipped.
    public struct Counters: Sendable, Equatable {
        /// Claims that took over a chunk holding records of this ring's current recording.
        public var chunksOverwritten: UInt64
        /// Claim tries that found their chunk owned or claimed by a newer lap.
        public var chunksSkipped: UInt64
        /// Records not written because four claim tries failed.
        public var recordsDropped: UInt64
        /// Names that found the table full.
        public var nameOverflow: UInt64
        /// Threads that found the table full.
        public var threadOverflow: UInt64
        /// Chunks the heap ring claimed after its copy into the file and before the swap.
        public var heapChunksLost: UInt64
        /// File adoptions that failed (open, preallocation or mmap) or were refused (the ring already
        /// had a file or another adoption ran); the ring stayed where it was.
        public var adoptFailures: UInt64
    }

    /// The calling thread's identity in the thread table.
    public struct ThreadIdentity: Sendable {
        /// `pthread_threadid_np`.
        public var tid: UInt64
        /// `qos_class_t` at registration.
        public var qos: UInt8
        /// `pthread_getname_np` (cut at 46 bytes).
        public var name: String

        public init(tid: UInt64, qos: UInt8, name: String) {
            self.tid = tid
            self.qos = qos
            self.name = name
        }

        /// The calling thread's tid, QoS class and name.
        public static func current() -> ThreadIdentity {
            var tid: UInt64 = 0
            pthread_threadid_np(nil, &tid)
            let capacity = 64
            var buffer = [CChar](repeating: 0, count: capacity)
            pthread_getname_np(pthread_self(), &buffer, capacity)
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return ThreadIdentity(tid: tid, qos: UInt8(truncatingIfNeeded: qos_class_self().rawValue),
                                  name: String(decoding: bytes, as: UTF8.self))
        }
    }

    // MARK: - Adoption (TraceRingFile)

    var activeRing: UnsafeMutablePointer<TraceRingActive>? {
        UnsafeMutablePointer(bitPattern: UInt(activeCell.load(ordering: .acquiring)))
    }

    /// Starts the one adoption this ring gets; false when one ran or runs.
    func beginAdoption() -> Bool {
        adoption.compareExchange(expected: 0, desired: 1, ordering: .acquiringAndReleasing).exchanged
    }

    /// Ends the adoption: a failed one may be tried again, a finished one never.
    func endAdoption(adopted: Bool) {
        adoption.store(adopted ? 2 : 0, ordering: .releasing)
    }

    /// Points writers at the file, whose header, tables and chunks are written. The heap is never freed:
    /// a writer that loaded it may still finish one record there.
    func activateFile(_ storage: TraceRingStorage) {
        activeCell.store(UInt64(UInt(bitPattern: TraceRingActive.make(storage, slot: TraceRingActive.fileSlot))), ordering: .releasing)
    }

    func countAdoptFailure() {
        adoptFailureCount.add(1, ordering: .relaxed)
    }

    /// The thread's state, made at its first write.
    @inline(__always)
    private func threadState() -> UnsafeMutablePointer<TraceRingThreadState>? {
        if let raw = pthread_getspecific(threadKey) {
            return raw.assumingMemoryBound(to: TraceRingThreadState.self)
        }
        return makeThreadState()
    }

    @inline(never)
    private func makeThreadState() -> UnsafeMutablePointer<TraceRingThreadState>? {
        let thread = threadIdentity()
        let state = UnsafeMutablePointer<TraceRingThreadState>.allocate(capacity: 1)
        state.initialize(to: TraceRingThreadState(tid: thread.tid, info: TraceRingThreadInfo(qos: thread.qos, name: Array(thread.name.utf8))))
        guard pthread_setspecific(threadKey, state) == 0 else {
            state.deinitialize(count: 1)
            state.deallocate()
            return nil
        }
        return state
    }
}

/// One ring a ``TraceRing`` writes or wrote to, and its slot (0 heap, 1 file). Allocated once per
/// activation and never freed, so its address also tells a writer that the active ring changed.
struct TraceRingActive {
    static let heapSlot = 0
    static let fileSlot = 1

    let storage: TraceRingStorage
    let slot: Int

    static func make(_ storage: TraceRingStorage, slot: Int) -> UnsafeMutablePointer<TraceRingActive> {
        let pointer = UnsafeMutablePointer<TraceRingActive>.allocate(capacity: 1)
        pointer.initialize(to: TraceRingActive(storage: storage, slot: slot))
        return pointer
    }
}

/// A thread's writer state for one ``TraceRing``: its owned chunk and its thread-table entry in each ring
/// slot. Only its thread touches it, through an unsafe pointer (no exclusivity check on the write path).
struct TraceRingThreadState {
    struct Entry {
        var ring: UnsafeMutablePointer<TraceRingActive>?
        var index: UInt32 = TraceRing.noThread
        var generation: UInt32 = 0
    }

    /// The ring holding the owned chunk (valid while `nextSlot` is not 0).
    var owner: UnsafeMutablePointer<TraceRingActive>?
    var chunk = 0
    var lap: UInt64 = 0
    /// The next slot (1-31) in the owned chunk; 0: no chunk.
    var nextSlot = 0
    var heapEntry = Entry()
    var fileEntry = Entry()
    let tid: UInt64
    let info: TraceRingThreadInfo

    init(tid: UInt64, info: TraceRingThreadInfo) {
        self.tid = tid
        self.info = info
    }

    /// The thread's entry in `active`'s ring, registered at its first claim there.
    static func entry(_ state: UnsafeMutablePointer<TraceRingThreadState>,
                      in active: UnsafeMutablePointer<TraceRingActive>) -> (index: UInt32, generation: UInt32) {
        let isFile = active.pointee.slot == TraceRingActive.fileSlot
        let known = isFile ? state.pointee.fileEntry : state.pointee.heapEntry
        if let ring = known.ring, ring.pointee.storage.base == active.pointee.storage.base {
            return (known.index, known.generation)
        }
        let made = active.pointee.storage.registerThread(tid: state.pointee.tid, info: state.pointee.info)
        let entry = Entry(ring: active, index: made.index, generation: made.generation)
        if isFile { state.pointee.fileEntry = entry } else { state.pointee.heapEntry = entry }
        return made
    }

    /// The thread-exit destructor: completes the owned chunk, marks the thread's entries exited and frees
    /// the state.
    static func threadExited(_ raw: UnsafeMutableRawPointer) {
        let state = raw.assumingMemoryBound(to: TraceRingThreadState.self)
        if state.pointee.nextSlot != 0, let owner = state.pointee.owner {
            owner.pointee.storage.complete(chunk: state.pointee.chunk, lap: state.pointee.lap)
        }
        for entry in [state.pointee.heapEntry, state.pointee.fileEntry] {
            guard let ring = entry.ring, entry.index != TraceRing.noThread else { continue }
            ring.pointee.storage.exitThread(index: entry.index, generation: entry.generation)
        }
        state.deinitialize(count: 1)
        state.deallocate()
    }
}
