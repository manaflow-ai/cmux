import CmuxNextCompat
import Darwin
import Foundation

/// A terminal's output ring, mapped read-only from the descriptor its RING
/// frame passed (`terminal-output-ring-v1`, plans/cmux-next/app-daemon-connection-DESIGN.md
/// section 4; the daemon's writer is cmux-tui `surface/output_ring.rs`).
///
/// Output reaches Ghostty as ``spans(from:to:onLap:)``: `Data` that points into
/// this mapping, copied by nobody. Every span holds the mapping, so it is
/// unmapped only after the last span is parsed and released and the stream
/// dropped it. The daemon never waits for a reader: a reader checks the
/// ring's `reserve` word before it hands out bytes and after they are parsed,
/// and a lapped read is a gap (the stream resyncs by snapshot).
final class TerminalOutputRingMapping: Sendable {

    static let header = 64
    private static let headerBytes: UInt64 = 64
    /// "CMAR" little endian.
    static let magic: UInt32 = 0x5241_4D43
    static let layout: UInt32 = 1
    /// The largest ring a reader maps (a corrupt header must not map gigabytes).
    static let maxCapacity: UInt64 = 64 << 20

    enum MappingError: Error, Equatable {
        case stat(Int32)
        case map(Int32)
        case notARing
    }

    let capacity: UInt64
    /// The offset of the first byte the ring ever held.
    let base: UInt64
    /// The mapping's address as an integer (a pointer is not `Sendable`): the
    /// mapping is read-only here and lives until deinit.
    private let address: UInt
    private let length: Int
    private let reserve: SharedMemoryWord

    /// Maps the ring behind `descriptor` and closes the descriptor (the
    /// mapping keeps the memory object alive).
    init(descriptor: Int32) throws(MappingError) {
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw .stat(errno) }
        guard let size = UInt64(exactly: status.st_size), size >= Self.headerBytes else { throw .notARing }
        guard let header = mmap(nil, Self.header, PROT_READ, MAP_SHARED, descriptor, 0), header != MAP_FAILED else {
            throw .map(errno)
        }
        let magic = header.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
        let layout = header.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let capacity = header.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
        let base = header.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
        munmap(header, Self.header)
        guard magic == Self.magic, layout == Self.layout, capacity > 0, capacity <= Self.maxCapacity,
              Self.headerBytes + capacity <= size,
              let length = Int(exactly: Self.headerBytes + capacity)
        else { throw .notARing }
        guard let address = mmap(nil, length, PROT_READ, MAP_SHARED, descriptor, 0), address != MAP_FAILED else {
            throw .map(errno)
        }
        self.address = UInt(bitPattern: address)
        self.length = length
        self.capacity = capacity
        self.base = base
        reserve = SharedMemoryWord(UnsafeRawPointer(address + 32))
    }

    /// The mapping's first byte (never nil: the bit pattern of mmap's result).
    private var pointer: UnsafeMutableRawPointer? { UnsafeMutableRawPointer(bitPattern: address) }

    deinit {
        munmap(pointer, length)
    }

    /// Whether the bytes from offset `from` on are still the ones the daemon
    /// published: false once its writer started to overwrite them.
    func unlapped(from: UInt64) -> Bool {
        SharedMemoryWord.acquireFence()
        return reserve.load(ordering: .relaxed) <= from + capacity
    }

    /// The most span bytes a reader may hold unreleased (queued or being
    /// parsed). A span stays valid until the writer has written `capacity`
    /// bytes past its start; with at most half the ring held, the writer must
    /// run half a ring ahead during one parse to lap a span that passed the cut
    /// check. A reader that would hold more is behind: it resyncs instead.
    var outstandingBudget: UInt64 { capacity / 2 }

    /// `[from, to)` as at most two zero-copy spans (the ring wraps between
    /// them). Foundation keeps a span of at most 14 bytes inline: it copies
    /// those bytes and runs the deallocator at once, whose lap check then
    /// validates the copy (a keystroke echo is such a span: copied, no heap).
    /// Returns nil when the bytes are already lost or being overwritten
    /// (checked before any span exists, so a lapped read never reaches the
    /// parser). Each span calls `onRelease` with its start, its length and
    /// whether the writer lapped it, when it is released after the parse; the
    /// caller must not hold a lock `onRelease` takes (an inline span releases
    /// inside this call).
    func spans(from: UInt64, to: UInt64,
               onRelease: @escaping @Sendable (_ start: UInt64, _ count: Int, _ lapped: Bool) -> Void) -> [Data]? {
        guard let mapped = pointer, from >= base, to >= from, to - from <= capacity, unlapped(from: from) else { return nil }
        var spans: [Data] = []
        var at = from
        while at < to {
            let start = at % capacity
            let take = min(to - at, capacity - start)
            guard let offset = Int(exactly: Self.headerBytes + start), let count = Int(exactly: take) else { return nil }
            let spanStart = at
            spans.append(Data(bytesNoCopy: mapped + offset, count: count, deallocator: .custom { [self] _, _ in
                // Released after the parse: was it overwritten while parsed?
                onRelease(spanStart, count, !self.unlapped(from: spanStart))
            }))
            at += take
        }
        return spans
    }

    /// Whether `pointer` lies inside the mapping (the zero-copy guard's check).
    func contains(_ candidate: UnsafeRawPointer) -> Bool {
        let at = UInt(bitPattern: candidate)
        return at >= address && at - address < UInt(truncatingIfNeeded: length)
    }
}
