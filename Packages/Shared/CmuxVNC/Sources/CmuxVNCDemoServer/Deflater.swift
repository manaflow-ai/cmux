import zlib

/// One deflate stream per connection, flushed per rectangle. Like the client's
/// ZlibStream, the `z_stream` stays at one heap address from `deflateInit_` to
/// `deflateEnd` (zlib refuses a moved stream, deflate.c deflateStateCheck), and its
/// `next_in` / `next_out` point into Swift arrays only during one `deflate` call.
final class Deflater {
    private let stream: UnsafeMutablePointer<z_stream>

    init() {
        // SAFETY: one z_stream, initialized on the next line and freed once in deinit.
        stream = unsafe UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        // SAFETY: the allocation above, not yet initialized.
        unsafe stream.initialize(to: z_stream())
        // SAFETY: deflateInit_ fills the initialized stream at its final address; it reads the
        // NUL-terminated version string Swift passes for this call only.
        _ = unsafe deflateInit_(stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    }

    deinit {
        // SAFETY: the stream init set up, ended once here (a failed init leaves no state to end).
        _ = unsafe deflateEnd(stream)
        // SAFETY: the one z_stream init initialized: deinitialized and freed once, here.
        unsafe stream.deinitialize(count: 1)
        // SAFETY: as above.
        unsafe stream.deallocate()
    }

    func deflate(_ input: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        input.withUnsafeBufferPointer { source in
            // SAFETY: next_in points at `source`, valid for this closure; zlib reads at most
            // avail_in = source.count bytes and never writes through it (the mutable pointer is
            // only zlib's declared type), and the defer clears it before the closure returns.
            unsafe stream.pointee.next_in = UnsafeMutablePointer(mutating: source.baseAddress)
            // SAFETY: the live stream; a field write.
            unsafe stream.pointee.avail_in = uInt(source.count)
            // SAFETY: the live stream; no pointer into `source` outlives the closure.
            defer { unsafe stream.pointee.next_in = nil }
            while true {
                let produced = chunk.withUnsafeMutableBufferPointer { out -> Int in
                    // SAFETY: next_out points at `out`, valid for this closure; zlib writes at most
                    // avail_out = out.count bytes, and the defer clears it before the closure returns.
                    unsafe stream.pointee.next_out = out.baseAddress
                    // SAFETY: the live stream; a field write.
                    unsafe stream.pointee.avail_out = uInt(out.count)
                    // SAFETY: the live stream; no pointer into `out` outlives the closure.
                    defer { unsafe stream.pointee.next_out = nil }
                    // SAFETY: the stream is initialized and its in/out windows are set above.
                    _ = unsafe zlib.deflate(stream, Z_SYNC_FLUSH)
                    // SAFETY: the live stream; a field read.
                    return unsafe out.count - Int(stream.pointee.avail_out)
                }
                result.append(contentsOf: chunk[0 ..< produced])
                // SAFETY: the live stream; a field read.
                let outputLeft = unsafe stream.pointee.avail_out
                guard outputLeft == 0 else { break }
            }
        }
        return result
    }
}
