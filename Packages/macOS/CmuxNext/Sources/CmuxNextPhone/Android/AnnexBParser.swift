import Foundation

/// Cuts an H.264 Annex B byte stream (start codes `00 00 01` or
/// `00 00 00 01`) into NAL units, across pipe chunks that split anywhere.
/// A unit is complete only when the next start code arrives.
///
/// The memory it holds is bounded whatever adb writes: bytes before the
/// first start code are dropped, and a unit whose payload grows past
/// `maxUnitBytes` before its next start code is dropped whole and reported
/// as ``Cut/dropped`` where it ended, so ``AndroidFrameAssembler`` waits for
/// the next keyframe, and the buffer never holds more than
/// `2 * (maxUnitBytes + 2)` bytes between calls. Consumed bytes stay at the
/// front until they are at least half the buffer, as Chromium's
/// `media/base/byte_queue.cc` keeps an offset instead of moving the queue on
/// every pop, so a unit that arrives in many small chunks is copied a bounded
/// number of times.
struct AnnexBParser {
    /// One thing the stream gave, in stream order.
    enum Cut: Equatable {
        /// A unit, without its start code or trailing zero bytes.
        case unit(Data)
        /// A unit longer than `maxUnitBytes` was skipped here.
        case dropped

        var unit: Data? {
            guard case let .unit(data) = self else { return nil }
            return data
        }
    }

    /// 8 MiB: a 4K IDR at screenrecord's bit rate is a few hundred KiB.
    static let defaultMaxUnitBytes = 8 << 20

    /// The largest unit payload kept; a longer unit is dropped.
    let maxUnitBytes: Int
    private var buffer: [UInt8] = []
    /// Where the live bytes start in `buffer`: the payload of the unit in
    /// progress, or the last bytes before any start code, which may begin one.
    private var head = 0
    /// How far `buffer` has been scanned for start codes.
    private var scanned = 0
    /// A start code was seen: `buffer[head...]` is a unit's payload.
    private var inUnit = false
    /// The unit in progress passed `maxUnitBytes`; it is skipped up to the next start code.
    private var discarding = false

    init(maxUnitBytes: Int = AnnexBParser.defaultMaxUnitBytes) {
        self.maxUnitBytes = max(maxUnitBytes, 0)
    }

    /// The bytes held between calls (for the fuzz suite's allocation bound).
    var bufferedByteCount: Int { buffer.count }

    /// Appends `chunk` and returns the units it completed, in order.
    mutating func append(_ chunk: Data) -> [Data] {
        cut(chunk).compactMap(\.unit)
    }

    /// Appends `chunk` and returns the units it completed and the over-limit units it skipped, in order.
    mutating func cut(_ chunk: Data) -> [Cut] {
        buffer.append(contentsOf: chunk)
        var cuts: [Cut] = []
        var i = scanned
        while i + 2 < buffer.count {
            guard buffer[i] == 0, buffer[i + 1] == 0, buffer[i + 2] == 1 else {
                i += 1
                continue
            }
            if inUnit, let cut = finishedCut(head..<i) { cuts.append(cut) }
            inUnit = true
            discarding = false
            head = i + 3
            i += 3
        }
        scanned = i
        // Two bytes after the payload may be the start of the next start code, so a unit is
        // over the limit for sure only past `maxUnitBytes + 2`.
        if !inUnit || discarding || buffer.count - head > maxUnitBytes + 2 {
            discarding = inUnit
            head = max(head, buffer.count - 2)
        }
        compact()
        return cuts
    }

    /// The unit in progress (at the end of the stream).
    mutating func flush() -> Data? {
        defer {
            buffer = []
            head = 0
            scanned = 0
            inUnit = false
            discarding = false
        }
        guard inUnit else { return nil }
        return finishedCut(head..<buffer.count)?.unit
    }

    /// The unit in `range` (between two start codes): `.dropped` when it is over the limit, nil when empty.
    private func finishedCut(_ range: Range<Int>) -> Cut? {
        guard !discarding, range.count <= maxUnitBytes else { return .dropped }
        var end = range.upperBound
        // A 4-byte start code's leading zero (and trailing_zero_8bits) belong to no unit.
        while end > range.lowerBound, buffer[end - 1] == 0 { end -= 1 }
        return end > range.lowerBound ? .unit(Data(buffer[range.lowerBound..<end])) : nil
    }

    /// Drops the consumed bytes once they are at least half the buffer.
    private mutating func compact() {
        guard head > 0, head >= buffer.count - head else { return }
        buffer.removeFirst(head)
        scanned -= head
        head = 0
    }
}
