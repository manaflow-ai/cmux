import CmuxNextTrace

extension MetricsStore {
    /// The alignment of the heap block and of each histogram's block (a cache line).
    static let blockAlignment = 64

    /// Where one histogram's counters are and how a sample picks its bucket.
    struct Slot: Sendable {
        /// The layout kind (``MetricsImage/Kind``).
        var kind: MetricsImage.Kind
        /// The maximum (log-linear, linear) or the value count (enumeration).
        var limit: Int64
        /// The overflow bucket's index.
        var overflow: Int
        /// The block's first word (its count) from the start of the image.
        var word: Int

        /// ``HistogramID/Layout/bucketIndex(of:)`` with the layout's numbers at hand.
        @inline(__always)
        func bucket(of sample: Int64) -> Int {
            switch kind {
            case .logLinear: sample > limit ? overflow : HistogramID.Layout.logLinearIndex(UInt64(max(sample, 0)))
            case .linear: sample > limit ? overflow : Int(max(sample, 0))
            case .enumeration: sample >= 0 && sample < limit ? Int(sample) : overflow
            }
        }
    }

    /// The header fields that are not the profile.
    struct Header {
        var role: TraceRuntime.Role
        var pid: UInt32
        var startUptimeNanos: UInt64
        var startUnixNanos: UInt64
        var profile: MetricsProfile
    }

    /// The directory and blocks of a catalog.
    struct Layout {
        struct Entry {
            var id: HistogramID
            var slot: Slot
            var bucketCount: Int
        }

        var entries: [Entry] = []
        var slots: [HistogramID: Slot] = [:]
        /// The first block's byte offset.
        var blocksOffset = 0
        /// The image's size.
        var byteCount = 0
        /// Set before ``image()``.
        var header: Header?

        init(catalog: [HistogramID]) {
            blocksOffset = MetricsImage.align(MetricsImage.directoryOffset + catalog.count * MetricsImage.entryBytes)
            var offset = blocksOffset
            for id in catalog {
                guard let kind = MetricsImage.Kind(id.layout) else { continue }
                let bucketCount = id.layout.bucketCount
                let limit: Int64 = switch id.layout {
                case let .logLinear(maximum), let .linear(maximum): maximum
                case let .enumeration(valueCount): Int64(valueCount)
                case .chromium: 0
                }
                let slot = Slot(kind: kind, limit: limit, overflow: bucketCount - 1, word: offset / 8)
                entries.append(Entry(id: id, slot: slot, bucketCount: bucketCount))
                slots[id] = slot
                offset += MetricsImage.align(MetricsImage.blockBytes(bucketCount: bucketCount))
            }
            byteCount = MetricsImage.align(max(offset, blocksOffset), to: 4096)
        }

        /// The header and directory bytes (everything before the first block).
        func image() -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: blocksOffset)
            bytes.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                for (index, byte) in MetricsImage.magic.enumerated() { base.storeBytes(of: byte, toByteOffset: index, as: UInt8.self) }
                base.storeBytes(of: MetricsImage.version.littleEndian, toByteOffset: 8, as: UInt32.self)
                base.storeBytes(of: UInt32(MetricsImage.directoryOffset).littleEndian, toByteOffset: 12, as: UInt32.self)
                base.storeBytes(of: UInt32(entries.count).littleEndian, toByteOffset: 16, as: UInt32.self)
                base.storeBytes(of: UInt16(HistogramID.Layout.logLinearSubBucketsLog2).littleEndian, toByteOffset: 22, as: UInt16.self)
                base.storeBytes(of: UInt32(MetricsImage.entryBytes).littleEndian, toByteOffset: 28, as: UInt32.self)
                base.storeBytes(of: UInt64(byteCount).littleEndian, toByteOffset: 48, as: UInt64.self)
                base.storeBytes(of: UInt64(blocksOffset).littleEndian, toByteOffset: 56, as: UInt64.self)
                if let header {
                    base.storeBytes(of: header.role.rawValue.littleEndian, toByteOffset: 20, as: UInt16.self)
                    base.storeBytes(of: header.pid.littleEndian, toByteOffset: 24, as: UInt32.self)
                    base.storeBytes(of: header.startUptimeNanos.littleEndian, toByteOffset: 32, as: UInt64.self)
                    base.storeBytes(of: header.startUnixNanos.littleEndian, toByteOffset: 40, as: UInt64.self)
                    header.profile.write(into: base)
                }
                for (index, entry) in entries.enumerated() {
                    let at = base + MetricsImage.directoryOffset + index * MetricsImage.entryBytes
                    for (position, byte) in entry.id.name.utf8.prefix(MetricsImage.nameBytes).enumerated() {
                        at.storeBytes(of: byte, toByteOffset: position, as: UInt8.self)
                    }
                    at.storeBytes(of: entry.slot.kind.rawValue.littleEndian, toByteOffset: 64, as: UInt32.self)
                    at.storeBytes(of: UInt32(entry.bucketCount).littleEndian, toByteOffset: 68, as: UInt32.self)
                    at.storeBytes(of: entry.slot.limit.littleEndian, toByteOffset: 72, as: Int64.self)
                    at.storeBytes(of: UInt64(entry.slot.word * 8).littleEndian, toByteOffset: 80, as: UInt64.self)
                }
            }
            return bytes
        }
    }
}
