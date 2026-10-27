import CmuxNextCompat

/// A metrics file's contents in memory (``MetricsStore``'s layout): its header, profile and counters, read in place.
/// The app's own store reads its active block through it; a fold of an earlier launch's file or a child process's
/// file (tasks 053, 062) maps the file and reads it the same way.
public struct MetricsImage {
    /// The image's first byte (a heap block or a mapping).
    let base: UnsafeMutableRawPointer
    /// The image's size.
    public let byteCount: Int
    /// The writer's process kind (`TraceRuntime.Role.rawValue`).
    public let role: UInt16
    /// The writer's pid.
    public let pid: UInt32
    /// The writer's system profile.
    public let profile: MetricsProfile
    /// The histograms, in directory order.
    let entries: [Entry]

    /// The directory's fields of one histogram.
    struct Entry {
        var name: String
        var layout: HistogramID.Layout
        var bucketCount: Int
        /// The block's byte offset.
        var offset: Int
    }

    /// A histogram layout kind as the directory writes it.
    enum Kind: UInt32, Sendable {
        case logLinear = 1
        case linear = 2
        case enumeration = 3

        /// The kind of `layout`; nil for Chromium's (it has no block).
        init?(_ layout: HistogramID.Layout) {
            switch layout {
            case .logLinear: self = .logLinear
            case .linear: self = .linear
            case .enumeration: self = .enumeration
            case .chromium: return nil
            }
        }
    }

    /// `CMXMETRC`.
    static let magic: [UInt8] = Array("CMXMETRC".utf8)
    /// The layout version.
    static let version: UInt32 = 1
    /// The directory's byte offset.
    static let directoryOffset = 1024
    /// One directory entry's bytes.
    static let entryBytes = 88
    /// A name's bytes in an entry.
    static let nameBytes = 64

    /// The bytes of a block with `bucketCount` buckets: count, sum and buckets, twice (current, logged).
    static func blockBytes(bucketCount: Int) -> Int { 2 * (2 + bucketCount) * 8 }

    /// `value` rounded up to a multiple of `alignment`.
    static func align(_ value: Int, to alignment: Int = MetricsStore.blockAlignment) -> Int {
        (value + alignment - 1) / alignment * alignment
    }

    /// Reads the image at `base`; nil when it is not a version 1 metrics image of at most `byteCount` bytes whose
    /// blocks all lie inside it. Loads only, so a read-only mapping is fine (``markLogged(_:)`` aside).
    public init?(validating base: UnsafeMutableRawPointer, byteCount: Int) {
        guard byteCount >= Self.directoryOffset,
              Array(UnsafeRawBufferPointer(start: base, count: 8)) == Self.magic,
              UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) == Self.version,
              Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 12, as: UInt32.self))) == Self.directoryOffset,
              Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 28, as: UInt32.self))) == Self.entryBytes else { return nil }
        let count = Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 16, as: UInt32.self)))
        guard Self.directoryOffset + count * Self.entryBytes <= byteCount else { return nil }
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        for index in 0 ..< count {
            let at = base + Self.directoryOffset + index * Self.entryBytes
            let name = String(decoding: UnsafeRawBufferPointer(start: at, count: Self.nameBytes).prefix(while: { $0 != 0 }), as: UTF8.self)
            let bucketCount = Int(UInt32(littleEndian: at.loadUnaligned(fromByteOffset: 68, as: UInt32.self)))
            let limit = Int64(littleEndian: at.loadUnaligned(fromByteOffset: 72, as: Int64.self))
            let offset = Int(clamping: UInt64(littleEndian: at.loadUnaligned(fromByteOffset: 80, as: UInt64.self)))
            let layout: HistogramID.Layout
            switch Kind(rawValue: UInt32(littleEndian: at.loadUnaligned(fromByteOffset: 64, as: UInt32.self))) {
            case .logLinear?: layout = .logLinear(maximum: limit)
            case .linear?: layout = .linear(maximum: limit)
            case .enumeration?: layout = .enumeration(valueCount: Int(clamping: limit))
            case nil: return nil
            }
            guard bucketCount > 0, offset % 8 == 0, offset >= Self.directoryOffset + count * Self.entryBytes,
                  offset <= byteCount - Self.blockBytes(bucketCount: bucketCount) else { return nil }
            entries.append(Entry(name: name, layout: layout, bucketCount: bucketCount, offset: offset))
        }
        self.base = base
        self.byteCount = byteCount
        self.entries = entries
        role = UInt16(littleEndian: base.loadUnaligned(fromByteOffset: 20, as: UInt16.self))
        pid = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 24, as: UInt32.self))
        profile = MetricsProfile(reading: base)
    }

    /// The names of the histograms, in directory order.
    public var names: [String] { entries.map(\.name) }

    /// Current minus logged for every histogram with a sample since the last ``markLogged(_:)``.
    public func delta() -> MetricsDelta {
        var histograms: [MetricsDelta.Histogram] = []
        for (position, entry) in entries.enumerated() {
            let words = (base + entry.offset).assumingMemoryBound(to: UInt64.self)
            let logged = words + 2 + entry.bucketCount
            func since(_ word: Int) -> UInt64 {
                AtomicPointerSlot(words + word).load(ordering: .relaxed) &- AtomicPointerSlot(logged + word).load(ordering: .relaxed)
            }
            let count = since(0)
            guard count != 0 else { continue }
            var buckets: [MetricsDelta.Bucket] = []
            for index in 0 ..< entry.bucketCount {
                let samples = since(2 + index)
                if samples != 0 { buckets.append(MetricsDelta.Bucket(index: index, count: samples)) }
            }
            histograms.append(MetricsDelta.Histogram(name: entry.name, layout: entry.layout, count: count, sum: since(1),
                                                     buckets: buckets, entry: position))
        }
        return MetricsDelta(profile: profile, histograms: histograms)
    }

    /// Adds `delta`'s numbers to the logged shadow (the image must be writable). A histogram whose directory position
    /// names another histogram (a delta of another image) is left alone.
    public func markLogged(_ delta: MetricsDelta) {
        for histogram in delta.histograms where entries.indices.contains(histogram.entry) {
            let entry = entries[histogram.entry]
            guard entry.name == histogram.name else { continue }
            let logged = (base + entry.offset).assumingMemoryBound(to: UInt64.self) + 2 + entry.bucketCount
            AtomicPointerSlot(logged).add(histogram.count, ordering: .relaxed)
            AtomicPointerSlot(logged + 1).add(histogram.sum, ordering: .relaxed)
            for bucket in histogram.buckets where bucket.index < entry.bucketCount {
                AtomicPointerSlot(logged + 2 + bucket.index).add(bucket.count, ordering: .relaxed)
            }
        }
    }
}

/// The samples a metrics image recorded since its last upload, per histogram (Chrome's `HistogramSnapshotManager`
/// deltas): what a hang report's `histograms[]` sends (task 063) and what `cmux metrics` shows (task 065).
public struct MetricsDelta: Sendable, Equatable {
    /// The profile of the launch that recorded the samples.
    public var profile: MetricsProfile
    /// The histograms with samples, in directory order.
    public var histograms: [Histogram]

    /// Whether no histogram has a sample.
    public var isEmpty: Bool { histograms.isEmpty }

    /// One histogram's samples since the last upload.
    public struct Histogram: Sendable, Equatable {
        /// The catalog name (``HistogramID/name``).
        public var name: String
        /// The bucket layout the samples were counted in.
        public var layout: HistogramID.Layout
        /// The samples.
        public var count: UInt64
        /// Their sum (a negative sample counted as 0).
        public var sum: UInt64
        /// The non-empty buckets, by index.
        public var buckets: [Bucket]
        /// The histogram's directory position in its image.
        let entry: Int
    }

    /// One bucket's samples.
    public struct Bucket: Sendable, Equatable {
        /// The bucket's index (``HistogramID/Layout/bucketRange(_:)`` gives its values).
        public var index: Int
        /// Its samples.
        public var count: UInt64
    }
}
