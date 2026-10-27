import CmuxNextCompat

extension TraceRing {
    /// A ring decoded from its own bytes: the header, the name table, the thread table and the whole records.
    /// Nothing comes from this build's catalog, so a ring an older or newer build wrote (other ids, other
    /// names, another case order) reads the same as one this build wrote (trace.md "Name table": each ring
    /// holds the full table for its own records). `cmux_trace::decode` is the Rust reader of the same bytes.
    public struct Image: Sendable {
        /// The header's process and ring fields (trace.md "Header").
        public struct Header: Sendable, Equatable {
            public let pid: UInt32
            /// The `role` u16; ``role`` reads it.
            public let roleCode: UInt16
            /// 1 black box, 2 recording.
            public let ringKind: UInt8
            /// 1 `CLOCK_UPTIME_RAW`, 2 Linux `CLOCK_MONOTONIC`, 3 Windows QPC nanoseconds.
            public let clockDomain: UInt8
            public let startUptimeNanos: UInt64
            public let startUnixNanos: UInt64
            public let startContinuousNanos: UInt64
            public let processStartUnixMicros: UInt64
            /// `kern.bootsessionuuid`, 16 bytes.
            public let bootSessionUUID: [UInt8]
            /// `LC_UUID` of the writer's main image, 16 bytes (zero when unknown).
            public let buildUUID: [UInt8]
            /// Version, build number and short commit.
            public let buildVersion: String
            /// The category bitset when the image was taken.
            public let categories: UInt64
            /// Names that found the table full (their records name id 0).
            public let nameOverflow: UInt32
            /// Threads that found the table full (their chunks name ``TraceRing/noThread``).
            public let threadOverflow: UInt32

            /// The process kind, or nil for a code this build does not know.
            public var role: Role? { Role(rawValue: roleCode) }
        }

        public let header: Header
        /// The published name entries, by id.
        public let names: [NameEntry]
        /// The live and exited thread entries, by index.
        public let threads: [ThreadEntry]
        /// The whole records, oldest first.
        public let records: [TraceRecord]
        let namesByID: [UInt16: NameEntry]
        let threadsByIndex: [UInt32: ThreadEntry]

        /// Decodes a ring image (``TraceRing/image()`` or a ring file's bytes); nil when it is not a whole v1 ring.
        public init?(bytes: [UInt8]) {
            guard let image = TraceRingStorage.withValidated(bytes: bytes, { Image($0) }) else { return nil }
            self = image
        }

        /// Reads a ring no thread writes (a validated copy). The records go first anyway, as
        /// ``TraceRingStorage/copy(into:)`` reads them, so every name and thread a record names is in the tables.
        private init(_ storage: TraceRingStorage) {
            typealias Offsets = TraceRingOffsets
            func load(_ offset: Int) -> UInt64 { storage.word(offset).load(ordering: .relaxed) }
            let identity = load(Offsets.identityWord)
            let overflow = load(Offsets.overflowWord)
            let version = storage.bytes(at: Offsets.buildVersion, words: 4)
            header = Header(
                pid: UInt32(truncatingIfNeeded: identity), roleCode: UInt16(truncatingIfNeeded: identity >> 32),
                ringKind: UInt8(truncatingIfNeeded: identity >> 48), clockDomain: UInt8(truncatingIfNeeded: identity >> 56),
                startUptimeNanos: load(Offsets.startUptime), startUnixNanos: load(Offsets.startUnix),
                startContinuousNanos: load(Offsets.startContinuous),
                processStartUnixMicros: load(Offsets.processStartUnixMicros),
                bootSessionUUID: storage.bytes(at: Offsets.bootSessionUUID, words: 2),
                buildUUID: storage.bytes(at: Offsets.buildUUID, words: 2),
                buildVersion: String(decoding: version.prefix { $0 != 0 }, as: UTF8.self),
                categories: load(Offsets.categories),
                nameOverflow: UInt32(truncatingIfNeeded: overflow), threadOverflow: UInt32(truncatingIfNeeded: overflow >> 32)
            )
            records = storage.decode()
            names = storage.nameEntries()
            threads = storage.threadEntries()
            // Two threads interning one name at once publish two entries with one text; either id reads right.
            namesByID = Dictionary(names.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            threadsByIndex = Dictionary(threads.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        }

        /// The ring's text for name `id`; nil for id 0 (a name that found the table full) or an id it lacks.
        public func name(_ id: UInt16) -> String? {
            namesByID[id]?.text
        }

        /// The ring's text for the name `record` carries.
        public func name(of record: TraceRecord) -> String? {
            name(record.name)
        }
    }

    /// The active ring decoded from its own tables, safe while threads write: it decodes ``image()``, whose
    /// copy reads the chunks before the tables, so each record's name and thread entry are in the image (a
    /// record or entry being written is left out).
    public func decodedImage() -> Image? {
        Image(bytes: image())
    }
}

extension TraceRingStorage {
    /// Runs `body` on an aligned copy of `bytes` (the decoder reads 8-byte words atomically) when it holds a
    /// whole v1 ring; nil otherwise. The copy is freed when `body` returns. Every decoder of ring bytes reads
    /// through this one check.
    static func withValidated<Result>(bytes: [UInt8], _ body: (TraceRingStorage) -> Result) -> Result? {
        let copy = UnsafeMutableRawPointer.allocate(byteCount: max(bytes.count, 8), alignment: 16)
        defer { copy.deallocate() }
        bytes.withUnsafeBytes { source in
            if let address = source.baseAddress { copy.copyMemory(from: address, byteCount: source.count) }
        }
        return TraceRingStorage(validating: copy, byteCount: bytes.count).map(body)
    }
}
