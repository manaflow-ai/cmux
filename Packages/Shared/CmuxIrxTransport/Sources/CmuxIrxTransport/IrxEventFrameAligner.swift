import Foundation

/// Splits a lane's byte stream at mobile-sync frame boundaries (4-byte
/// big-endian length + payload). Readers that merge several lanes into one
/// consumer must only forward whole frames, or bytes from two lanes would
/// interleave inside a frame.
struct IrxEventFrameAligner: Sendable {
    enum Failure: Error, Equatable {
        case frameTooLarge(Int)
    }

    static let headerByteCount = 4

    let maximumFrameByteCount: Int
    private var buffer = Data()

    init(maximumFrameByteCount: Int) {
        self.maximumFrameByteCount = maximumFrameByteCount
    }

    var hasPartialFrame: Bool { !buffer.isEmpty }

    /// Appends `chunk` and returns every complete frame now available, still
    /// framed, as one contiguous block; nil when no frame completed.
    mutating func append(_ chunk: Data) throws -> Data? {
        buffer.append(chunk)
        var reader = WireByteReader(buffer)
        var consumed = 0
        while true {
            guard let header = reader.bigEndian(UInt32.self) else { break }
            let length = Int(clamping: header)
            guard length <= maximumFrameByteCount else {
                throw Failure.frameTooLarge(length)
            }
            guard reader.skip(length) else { break }
            consumed += Self.headerByteCount + length
        }
        guard consumed > 0 else { return nil }
        let complete = Data(buffer.prefix(consumed))
        buffer.removeFirst(consumed)
        return complete
    }
}
