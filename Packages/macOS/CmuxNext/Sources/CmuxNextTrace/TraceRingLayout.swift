/// Ring v1 byte offsets and region placement: every number is one of the tables in
/// plans/cmux-next/trace.md, "Release trace ring v1", which the Rust writer
/// (`cmux-tui/crates/cmux-trace/src/layout.rs`) and the C writer also follow. The shared golden file
/// `Tests/CmuxNextTraceTests/Fixtures/ring-v1-golden.cmxtrace` pins the bytes.
///
/// Swift touches the ring through aligned 64-bit atomic words. A word that holds two u32 fields (or
/// smaller ones) is stored whole, little-endian, so its bytes are the same as two 32-bit stores.
enum TraceRingOffsets {
    static let magic = 0
    /// `version` u32 at 8, `header_bytes` u32 at 12.
    static let versionWord = 8
    /// `pid` u32 at 16, `role` u16 at 20, `ring_kind` u8 at 22, `clock_domain` u8 at 23.
    static let identityWord = 16
    static let startUptime = 24
    static let startUnix = 32
    static let processStartUnixMicros = 40
    static let bootSessionUUID = 48
    static let buildUUID = 64
    static let buildVersion = 80
    /// `chunk_bytes` u32 at 112, `chunk_count` u32 at 116.
    static let chunkGeometryWord = 112
    static let chunksOffset = 120
    static let chunkCursor = 128
    static let nameTableOffset = 136
    /// `name_capacity` u32 at 144, `name_cursor` u32 at 148.
    static let nameWord = 144
    static let threadTableOffset = 152
    /// `thread_capacity` u32 at 160, `thread_cursor` u32 at 164.
    static let threadWord = 160
    static let categories = 168
    static let chunksSkipped = 176
    static let recordsDropped = 184
    /// `name_overflow` u32 at 192, `thread_overflow` u32 at 196.
    static let overflowWord = 192
    static let heapCursor = 200
    static let startContinuous = 208
    static let chunksOverwritten = 216
    static let recordingStartCursor = 224
    /// `heap_chunks_lost` u32 at 232, then reserved zero bytes.
    static let heapChunksLostWord = 232

    // Chunk header (slot 0 of a chunk).
    /// `thread_index` u32 at 0, `thread_generation` u32 at 4.
    static let chunkThreadWord = 0
    static let chunkLapSeq = 8
    /// `published` u32 at 16, then reserved zero bytes.
    static let chunkPublishedWord = 16

    // Record.
    static let recordTime = 0
    /// `seq` u32 at 8, `name` u16 at 12, `phase` u8 at 14, `flags` u8 at 15.
    static let recordSeqWord = 8
    static let recordArg0 = 16
    static let recordArg1 = 24

    // Name entry: `state` u32 at 0 with `id` u16, `kind` u8 and `category` u8 at 4; `name_len` at 8; text at 9.
    // Thread entry: `state` u32 at 0 with `generation` u32 at 4; `tid` at 8; `qos` at 16, `name_len` at 17, name at 18.
    static let entryStateWord = 0
    static let entryTextWord = 8
    static let threadTid = 8
    static let threadInfoWord = 16
}

extension TraceRing {
    /// ASCII `CMXTRACE` read as a little-endian u64.
    static let magic: UInt64 = 0x4543_4152_5458_4D43
    /// Bytes in the header.
    public static let headerBytes = 256
    /// Every region starts on a 16 KiB page (`chunks_offset` must be a multiple of it).
    public static let pageBytes = 16384
    /// Bytes in one chunk: a 32-byte chunk header in slot 0, then ``recordsPerChunk`` records.
    public static let chunkBytes = 1024
    /// Bytes in one record.
    public static let recordBytes = 32
    /// Records in one chunk (slots 1-31).
    public static let recordsPerChunk = 31
    /// Bytes in one name-table or thread-table entry.
    public static let entryBytes = 64
    /// The ring format version this writer produces and the only one the decoder reads.
    public static let version: UInt32 = 1
    /// Claim tries before a record is dropped ("Claim a chunk").
    static let claimTries = 4
    /// The thread index of a chunk whose owner found the thread table full.
    public static let noThread: UInt32 = 0xFFFF_FFFF
    /// The most chunks a ring has.
    static let maxChunks = 1 << 20
    /// The most name entries a ring has (a name id is a u16).
    static let maxNames = 65536
    /// The most thread entries a ring has.
    static let maxThreads = 65536

    /// Entry states (the low u32 of an entry's first word).
    static let entryWriting: UInt64 = 1
    static let entryPublished: UInt64 = 2
    static let threadExited: UInt64 = 3

    /// The process kind written into the header (`role` u16 at offset 20) and its file-name stem; the
    /// codes are trace.md's and the Rust crate's `Role`.
    public enum Role: UInt16, Sendable, CaseIterable {
        case app = 1
        case daemon = 2
        case holder = 3
        case terminalHost = 4
        case acpmux = 5
        case chromiumHost = 6
        case cli = 7
        case agentHost = 8
        case appHost = 9
        case browserHost = 10

        /// The stem of this role's ring files (`app`, `terminal-host`, ...).
        public var fileStem: String {
            switch self {
            case .app: "app"
            case .daemon: "daemon"
            case .holder: "holder"
            case .terminalHost: "terminal-host"
            case .acpmux: "acpmux"
            case .chromiumHost: "chromium-host"
            case .cli: "cli"
            case .agentHost: "agent-host"
            case .appHost: "app-host"
            case .browserHost: "browser-host"
            }
        }
    }

    /// A ring's table capacities and chunk count, rounded to what the format allows: a power-of-two
    /// chunk count, whole 16 KiB pages of thread entries and at most 65536 names.
    public struct Sizes: Sendable, Equatable {
        public let nameCapacity: Int
        public let threadCapacity: Int
        public let chunkCount: Int

        public init(nameCapacity: Int, threadCapacity: Int, chunkCount: Int) {
            let threadsPerPage = TraceRing.pageBytes / TraceRing.entryBytes
            self.nameCapacity = min(max(nameCapacity, 1), TraceRing.maxNames)
            let threads = min(max(threadCapacity, 1), TraceRing.maxThreads)
            self.threadCapacity = (threads + threadsPerPage - 1) / threadsPerPage * threadsPerPage
            self.chunkCount = Self.powerOfTwo(atLeast: min(max(chunkCount, 1), TraceRing.maxChunks))
        }

        /// Room for at least `records` records, with small tables (tests and short-lived tools; a role's
        /// real sizes are trace.md's "Sizes by role").
        public init(records: Int, nameCapacity: Int = 64, threadCapacity: Int = 256) {
            let chunks = (max(records, 1) + TraceRing.recordsPerChunk - 1) / TraceRing.recordsPerChunk
            self.init(nameCapacity: nameCapacity, threadCapacity: threadCapacity, chunkCount: chunks)
        }

        /// The records the chunks hold.
        public var records: Int { chunkCount * TraceRing.recordsPerChunk }

        private static func powerOfTwo(atLeast value: Int) -> Int {
            var result = 1
            while result < value { result <<= 1 }
            return result
        }
    }

    /// What the header says about the writing process (trace.md "Header"). The start times and the
    /// identity are read once by the ring's creator (task 005); zero means unknown.
    public struct Identity: Sendable, Equatable {
        public var pid: UInt32
        public var role: Role
        /// 1 black box, 2 recording.
        public var ringKind: UInt8
        /// 1 `CLOCK_UPTIME_RAW`, 2 Linux `CLOCK_MONOTONIC`, 3 Windows QPC nanoseconds.
        public var clockDomain: UInt8
        public var startUptimeNanos: UInt64
        public var startUnixNanos: UInt64
        public var startContinuousNanos: UInt64
        public var processStartUnixMicros: UInt64
        /// 16 bytes (shorter is zero padded).
        public var bootSessionUUID: [UInt8]
        /// 16 bytes (shorter is zero padded).
        public var buildUUID: [UInt8]
        /// ASCII, at most 32 bytes.
        public var buildVersion: String
        /// The category bitset mirrored into the header.
        public var categories: UInt64

        public init(pid: UInt32, role: Role, ringKind: UInt8 = 1, clockDomain: UInt8 = 1,
                    startUptimeNanos: UInt64 = 0, startUnixNanos: UInt64 = 0, startContinuousNanos: UInt64 = 0,
                    processStartUnixMicros: UInt64 = 0, bootSessionUUID: [UInt8] = [], buildUUID: [UInt8] = [],
                    buildVersion: String = "", categories: UInt64 = 0) {
            self.pid = pid
            self.role = role
            self.ringKind = ringKind
            self.clockDomain = clockDomain
            self.startUptimeNanos = startUptimeNanos
            self.startUnixNanos = startUnixNanos
            self.startContinuousNanos = startContinuousNanos
            self.processStartUnixMicros = processStartUnixMicros
            self.bootSessionUUID = bootSessionUUID
            self.buildUUID = buildUUID
            self.buildVersion = buildVersion
            self.categories = categories
        }
    }

    /// One fixed name-table entry the ring's creator writes before the ring becomes active, so its id is
    /// the same in every ring of the process (trace.md "Name table").
    public struct CatalogName: Sendable {
        /// The entry index, from 1.
        public let id: UInt16
        /// 1 catalog name, 3 category.
        public let kind: UInt8
        /// The category bit (a category entry: its own bit).
        public let category: UInt8
        /// UTF-8, cut at 55 bytes.
        public let text: StaticString

        public init(id: UInt16, kind: UInt8, category: UInt8, text: StaticString) {
            self.id = id
            self.kind = kind
            self.category = category
            self.text = text
        }
    }
}

/// Where each region sits: the header page, the name table, the thread table, then the chunks, each on
/// a 16 KiB page. The writer computes it from ``TraceRing/Sizes``; a decoder takes every offset from the
/// header and only checks that the regions fit.
struct TraceRingLayout: Equatable {
    let nameCapacity: Int
    let threadCapacity: Int
    let chunkCount: Int
    let nameTableOffset: Int
    let threadTableOffset: Int
    let chunksOffset: Int
    let totalBytes: Int

    init(_ sizes: TraceRing.Sizes) {
        let page = TraceRing.pageBytes
        func pages(_ bytes: Int) -> Int { (bytes + page - 1) / page * page }
        nameCapacity = sizes.nameCapacity
        threadCapacity = sizes.threadCapacity
        chunkCount = sizes.chunkCount
        nameTableOffset = page
        threadTableOffset = nameTableOffset + pages(sizes.nameCapacity * TraceRing.entryBytes)
        chunksOffset = threadTableOffset + pages(sizes.threadCapacity * TraceRing.entryBytes)
        totalBytes = chunksOffset + sizes.chunkCount * TraceRing.chunkBytes
    }

    /// The layout a header names, when it is a whole v1 ring of at most `byteCount` bytes.
    init?(header: (Int) -> UInt64, byteCount: Int) {
        guard byteCount >= TraceRing.headerBytes, header(TraceRingOffsets.magic) == TraceRing.magic else { return nil }
        let versionWord = header(TraceRingOffsets.versionWord)
        guard UInt32(truncatingIfNeeded: versionWord) == TraceRing.version,
              versionWord >> 32 == UInt64(TraceRing.headerBytes) else { return nil }
        let geometry = header(TraceRingOffsets.chunkGeometryWord)
        let count = Int(geometry >> 32)
        let names = Int(UInt32(truncatingIfNeeded: header(TraceRingOffsets.nameWord)))
        let threads = Int(UInt32(truncatingIfNeeded: header(TraceRingOffsets.threadWord)))
        guard UInt32(truncatingIfNeeded: geometry) == UInt32(TraceRing.chunkBytes),
              count > 0, count <= TraceRing.maxChunks, count & (count - 1) == 0,
              names <= TraceRing.maxNames, threads <= TraceRing.maxThreads else { return nil }
        let chunks = header(TraceRingOffsets.chunksOffset)
        let nameTable = header(TraceRingOffsets.nameTableOffset)
        let threadTable = header(TraceRingOffsets.threadTableOffset)
        let limit = UInt64(byteCount)
        let headerEnd = UInt64(TraceRing.headerBytes)
        func fits(_ offset: UInt64, _ bytes: Int) -> Bool {
            offset >= headerEnd && offset % 8 == 0 && offset <= limit && UInt64(bytes) <= limit - offset
        }
        guard chunks % UInt64(TraceRing.pageBytes) == 0, fits(chunks, count * TraceRing.chunkBytes),
              fits(nameTable, names * TraceRing.entryBytes), fits(threadTable, threads * TraceRing.entryBytes)
        else { return nil }
        nameCapacity = names
        threadCapacity = threads
        chunkCount = count
        nameTableOffset = Int(nameTable)
        threadTableOffset = Int(threadTable)
        chunksOffset = Int(chunks)
        totalBytes = Int(chunks) + count * TraceRing.chunkBytes
    }

    func nameEntry(_ index: Int) -> Int { nameTableOffset + index * TraceRing.entryBytes }
    func threadEntry(_ index: Int) -> Int { threadTableOffset + index * TraceRing.entryBytes }
    func chunk(_ index: Int) -> Int { chunksOffset + index * TraceRing.chunkBytes }
}

/// `lap_seq` and record `seq` values (trace.md "Chunk" and "Record").
extension TraceRingLayout {
    @inline(__always) static func lapOwned(_ lap: UInt64) -> UInt64 { 2 &* lap &+ 1 }
    @inline(__always) static func lapComplete(_ lap: UInt64) -> UInt64 { 2 &* lap &+ 2 }
    @inline(__always) static func lap(ofLapSeq lapSeq: UInt64) -> UInt64 { (lapSeq &- 1) / 2 }
    @inline(__always) static func seqWriting(_ lap: UInt64) -> UInt32 { UInt32(truncatingIfNeeded: lapOwned(lap)) }
    @inline(__always) static func seqPublished(_ lap: UInt64) -> UInt32 { UInt32(truncatingIfNeeded: lapComplete(lap)) }
}
