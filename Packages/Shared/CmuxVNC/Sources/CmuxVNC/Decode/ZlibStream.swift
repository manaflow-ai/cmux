import Foundation
import zlib

/// One persistent inflate stream. RFB's Zlib and ZRLE encodings each keep a
/// single zlib stream for the whole connection, flushed per rectangle.
final class ZlibStream {
    private let stream: UnsafeMutablePointer<z_stream>
    private var output = [UInt8](repeating: 0, count: 1 << 16)

    init() throws {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        let status = inflateInit_(stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            stream.deallocate()
            throw RFBError.protocolViolation("zlib init \(status)")
        }
    }

    deinit {
        inflateEnd(stream)
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    /// Inflates every byte of `input`; returns all the output it produced.
    /// Throws once the output passes `limit` (a decompression bomb).
    func inflate(_ input: UnsafeBufferPointer<UInt8>, limit: Int) throws -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(min(limit, max(input.count * 4, 1 << 16)))
        guard let base = input.baseAddress, !input.isEmpty else { return result }
        stream.pointee.next_in = UnsafeMutablePointer(mutating: base)
        stream.pointee.avail_in = uInt(input.count)
        let capacity = output.count
        repeat {
            let produced: Int = try output.withUnsafeMutableBufferPointer { out in
                stream.pointee.next_out = out.baseAddress
                stream.pointee.avail_out = uInt(capacity)
                let status = zlib.inflate(stream, Z_SYNC_FLUSH)
                guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                    throw RFBError.protocolViolation("zlib inflate \(status)")
                }
                return capacity - Int(stream.pointee.avail_out)
            }
            result.append(contentsOf: output[0 ..< produced])
            guard result.count <= limit else { throw RFBError.protocolViolation("compressed rectangle inflates past \(limit) bytes") }
            if produced == 0 { break }
        } while stream.pointee.avail_in > 0 || stream.pointee.avail_out == 0
        stream.pointee.next_in = nil
        return result
    }
}
