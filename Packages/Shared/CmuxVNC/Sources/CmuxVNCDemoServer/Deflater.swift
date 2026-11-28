import zlib

/// One deflate stream per connection, flushed per rectangle.
final class Deflater {
    private let stream: UnsafeMutablePointer<z_stream>

    init() {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        deflateInit_(stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    }

    deinit {
        deflateEnd(stream)
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    func deflate(_ input: [UInt8]) -> [UInt8] {
        var input = input
        var result: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        input.withUnsafeMutableBufferPointer { source in
            stream.pointee.next_in = source.baseAddress
            stream.pointee.avail_in = uInt(source.count)
            repeat {
                let produced = chunk.withUnsafeMutableBufferPointer { out -> Int in
                    stream.pointee.next_out = out.baseAddress
                    stream.pointee.avail_out = uInt(out.count)
                    zlib.deflate(stream, Z_SYNC_FLUSH)
                    return out.count - Int(stream.pointee.avail_out)
                }
                result.append(contentsOf: chunk[0 ..< produced])
            } while stream.pointee.avail_out == 0
        }
        return result
    }
}
