import CmuxNextCompat
import Darwin

/// One process's trace ring v1: 32-byte records in 1 KiB chunks, each chunk owned by one writing thread,
/// so threads never contend on a record.
///
/// This is Perfetto's shared-memory writer design (`src/tracing/core/shared_memory_abi.cc`,
/// `SharedMemoryABI::TryAcquireChunk`): a writer owns its chunk until the chunk is full, then claims the
/// next with one `fetch_add` on the chunk cursor and one compare-and-swap of the chunk header, which skips
/// a chunk another live writer still owns. Unlike Perfetto there is no consumer: when the cursor wraps,
/// the claim overwrites the oldest chunk (black-box semantics) and counts the overwrite.
///
/// ``write(name:phase:flags:timestamp:arg0:arg1:)`` takes no lock, allocates nothing, makes no system call
/// and calls no Foundation: one load of the storage address, one `pthread_getspecific`, three loads and six
/// stores into the thread's own chunk. Every 31st write also claims a chunk.
///
/// The ring starts on the heap. ``TraceRingFile/adopt(_:directory:records:)`` moves it into a `MAP_SHARED`
/// file off main. No storage is ever freed or unmapped, so a writer that still holds an old chunk never
/// faults; the process ring lives as long as the process, like Chrome's `TraceLog`.
///
/// Byte layout (little-endian; Swift, Rust and C share it):
/// - Header, 1024 bytes: `magic u64` (0, "CMXTRACE"), `version u32` (8), `header bytes u32` (12),
///   `pid u32` (16), `chunk bytes u32` (20), `chunk count u64` (24), `chunk offset u64` (32),
///   `start uptime ns u64` (40), `name table offset u64` (48), `thread table offset u64` (56),
///   `role` 16 ASCII bytes (64), `build id` 16 bytes (80), `boot session` 16 bytes (96), `file backed u64`
///   (112); the `chunk cursor u64` (256) alone on its cache line; the counters `overwritten chunks u64`
///   (384), `skipped owned chunks u64` (392) and `dropped records u64` (400).
/// - Chunk, 1024 bytes: slot 0 is the chunk header: `thread index u32` (0), `thread generation u32` (4),
///   `lap word u64` (8: 0 = never claimed, else lap + 1, with bit 63 set while a live writer owns the
///   chunk), `published u32` (16: records 1...published are written), reserved (20). Slots 1-31 are records.
/// - Record, 32 bytes: `t_ns u64` (0), `seq u32` (8: `2*lap+1` while writing, `2*lap+2` when published),
///   `name u16` (12), `phase u8` (14), `flags u8` (15), `arg0 u64` (16), `arg1 u64` (24).
///
/// A decoder accepts a record only in a slot below the chunk's published count, with the published
/// sequence of the chunk's lap, and unchanged across its read.
public final class TraceRing: Sendable {
    /// Bytes in one record.
    public static let recordBytes = 32
    /// Bytes in one chunk: its header slot and ``recordsPerChunk`` records.
    public static let chunkBytes = 1024
    /// Records in one chunk.
    public static let recordsPerChunk = 31
    /// Bytes in the ring header, before the first chunk.
    public static let headerBytes = 1024
    /// The format version this writer produces.
    public static let version: UInt32 = 1

    /// The process role written into the header and used in the file name ("app", "daemon", ...).
    public let role: String
    /// The process id written into the header.
    public let pid: Int32

    /// The address of the storage writers use: the heap block first, then a mapped file. The word itself
    /// is a heap allocation that lives as long as the process.
    private let storageCell: AtomicPointerSlot
    /// The thread's owned chunk in the current storage, or none.
    private let chunkKey: pthread_key_t
    /// The thread's chunk-header word plus one (zero: not assigned yet).
    private let threadKey: pthread_key_t
    private let hasThreadKeys: Bool
    private let nextThreadIndex = Atomic<UInt64>(0)
    private let adoptFailureCount = Atomic<UInt64>(0)

    /// Makes a heap ring that holds at least `records` records. Its memory is never freed (a thread may
    /// hold a chunk in it until that thread exits), so a process makes one ring per use, for its lifetime.
    ///
    /// - Parameters:
    ///   - records: the capacity in records; rounded up to whole chunks (at least 2).
    ///   - role: the process role: up to 16 ASCII letters, digits, `-` or `_` (other characters are dropped).
    ///   - pid: the process id for the header; nil: this process.
    ///   - startUptimeNanos: the process start on the `CLOCK_UPTIME_RAW` clock (TraceClock).
    public init(records: Int, role: String, pid: Int32? = nil, startUptimeNanos: UInt64 = 0) {
        let allowed = role.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x30 ... 0x39, 0x41 ... 0x5A, 0x61 ... 0x7A, 0x2D, 0x5F: true
            default: false
            }
        }
        let cleanRole = String(String.UnicodeScalarView(allowed.prefix(16)))
        let headerRole = cleanRole.isEmpty ? "process" : cleanRole
        let headerPid = pid ?? getpid()
        self.role = headerRole
        self.pid = headerPid
        let chunkCount = Self.chunkCount(forRecords: records)
        let bytes = Self.storageBytes(chunkCount: chunkCount)
        let heap = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 128)
        heap.initializeMemory(as: UInt64.self, repeating: 0, count: bytes / 8)
        TraceRingStorage(heap).writeHeader(chunkCount: chunkCount, role: headerRole, pid: headerPid,
                                           startUptimeNanos: startUptimeNanos, fileBacked: false)
        let cell = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        cell.initialize(to: UInt64(UInt(bitPattern: heap)))
        storageCell = AtomicPointerSlot(cell)
        var chunk = pthread_key_t()
        var thread = pthread_key_t()
        // A thread that exits gives its chunk back, so short-lived threads do not keep chunks owned.
        let chunkKeyMade = pthread_key_create(&chunk) { TraceRingStorage.releaseChunk($0) } == 0
        let threadKeyMade = pthread_key_create(&thread, nil) == 0
        chunkKey = chunk
        threadKey = thread
        // Without its thread keys (the process ran out) the ring records nothing.
        hasThreadKeys = chunkKeyMade && threadKeyMade
    }

    /// The chunks needed for `records` records (at least 2).
    public static func chunkCount(forRecords records: Int) -> Int {
        max(2, (max(0, records) + recordsPerChunk - 1) / recordsPerChunk)
    }

    /// The bytes of a ring (header and chunks) with `chunkCount` chunks: the heap block or the file size.
    public static func storageBytes(chunkCount: Int) -> Int {
        headerBytes + chunkCount * chunkBytes
    }

    /// Appends one record. Lock-free, allocation-free, no system call: safe from any thread, a signal
    /// handler or a forked child. When every chunk is owned by another live thread, the record is
    /// dropped and counted.
    ///
    /// - Parameters:
    ///   - name: the catalog name id.
    ///   - phase: begin, end, instant, async, flow or counter.
    ///   - flags: bit 0: `arg1` is an async or track id; bit 1: the time is estimated.
    ///   - timestamp: `CLOCK_UPTIME_RAW` nanoseconds (TraceClock).
    ///   - arg0: the first argument.
    ///   - arg1: the second argument.
    // perf-hot: 60ns trace-ring-write
    public func write(name: UInt16, phase: TraceRecord.Phase, flags: UInt8 = 0, timestamp: UInt64,
                      arg0: UInt64 = 0, arg1: UInt64 = 0) {
        guard hasThreadKeys, let storage = currentStorage else { return }
        var chunk = pthread_getspecific(chunkKey)
        // A full chunk, or one in a storage the ring has left (after adoption), is given back.
        var published = UInt64(Self.recordsPerChunk)
        if let owned = chunk, storage.contains(owned) {
            published = TraceRingStorage.word(owned, TraceRingStorage.chunkPublished).load(ordering: .relaxed)
        }
        if published >= UInt64(Self.recordsPerChunk) {
            chunk = claim(in: storage, previous: chunk)
            published = 0
        }
        guard let chunk else { return }
        TraceRingStorage.publish(chunk: chunk, slot: Int(published) + 1, lap: TraceRingStorage.lap(ofOwned: chunk),
                                 name: name, phase: phase.rawValue, flags: flags, timestamp: timestamp, arg0: arg0, arg1: arg1)
    }

    /// The whole records in the current storage, oldest first (by time, then by write order). Safe while
    /// threads write: a record being written or overwritten is left out.
    public func records() -> [TraceRecord] {
        currentStorage?.decode() ?? []
    }

    /// A v1 ring image of the current storage (header and chunks) that holds only whole records, safe
    /// while threads write. ``records(inImage:)`` decodes it; the exporter writes it out.
    public func image() -> [UInt8] {
        currentStorage?.image() ?? []
    }

    /// Decodes a ring image (``image()`` or a ring file's bytes); nil when it is not a whole v1 ring.
    public static func records(inImage bytes: [UInt8]) -> [TraceRecord]? {
        // An aligned copy: the decoder reads 8-byte words atomically.
        let copy = UnsafeMutableRawPointer.allocate(byteCount: max(bytes.count, 8), alignment: 128)
        defer { copy.deallocate() }
        bytes.withUnsafeBytes { source in
            if let address = source.baseAddress { copy.copyMemory(from: address, byteCount: source.count) }
        }
        return TraceRingStorage(validating: copy, byteCount: bytes.count)?.decode()
    }

    /// Whether writes go to a mapped file rather than the heap.
    public var isFileBacked: Bool {
        currentStorage?.isFileBacked ?? false
    }

    /// The records the current storage holds when full.
    public var capacity: Int {
        (currentStorage?.chunkCount ?? 0) * Self.recordsPerChunk
    }

    /// What the ring lost or skipped so far.
    public var counters: Counters {
        let storage = currentStorage
        return Counters(
            overwrittenChunks: storage?.counter(TraceRingStorage.headerOverwritten) ?? 0,
            skippedOwnedChunks: storage?.counter(TraceRingStorage.headerSkipped) ?? 0,
            droppedRecords: storage?.counter(TraceRingStorage.headerDropped) ?? 0,
            adoptFailures: adoptFailureCount.load(ordering: .relaxed)
        )
    }

    /// What a ring lost or skipped.
    public struct Counters: Sendable, Equatable {
        /// Chunks a claim took back from an older lap (black-box overwrite).
        public var overwrittenChunks: UInt64
        /// Claims that passed over a chunk another live thread still owned.
        public var skippedOwnedChunks: UInt64
        /// Records dropped because every chunk was owned by another live thread.
        public var droppedRecords: UInt64
        /// File adoptions that failed (open, preallocation or mmap); the ring stayed where it was.
        public var adoptFailures: UInt64
    }

    // MARK: - Storage swap (TraceRingFile)

    var currentStorage: TraceRingStorage? {
        TraceRingStorage(address: UInt(storageCell.load(ordering: .acquiring)))
    }

    /// Points writers at `storage`, whose header is written. The old storage is never freed: a writer may
    /// still finish one record in a chunk there before its next write moves it.
    func swapStorage(to storage: TraceRingStorage) {
        storageCell.store(UInt64(UInt(bitPattern: storage.base)), ordering: .releasing)
    }

    func countAdoptFailure() {
        adoptFailureCount.add(1, ordering: .relaxed)
    }

    /// Gives back the thread's full chunk (when it is in `storage`) and claims the next one.
    private func claim(in storage: TraceRingStorage, previous: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        if let previous {
            TraceRingStorage.releaseChunk(previous)
        }
        let chunk = storage.acquireChunk(threadWord: threadWord())
        pthread_setspecific(chunkKey, chunk)
        return chunk
    }

    /// The calling thread's chunk-header word, assigned at its first claim. Task 004's thread table
    /// replaces this counter with a registered index and generation.
    private func threadWord() -> UInt64 {
        if let stored = pthread_getspecific(threadKey) {
            return UInt64(UInt(bitPattern: stored)) &- 1
        }
        let index = nextThreadIndex.add(1, ordering: .relaxed).oldValue & 0xFFFF_FFFF
        pthread_setspecific(threadKey, UnsafeRawPointer(bitPattern: UInt(index + 1)))
        return index
    }
}
