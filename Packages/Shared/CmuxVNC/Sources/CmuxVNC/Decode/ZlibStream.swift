import Foundation
import zlib

/// One persistent inflate stream. RFB's Zlib and ZRLE encodings each keep a
/// single zlib stream for the whole connection, flushed per rectangle.
///
/// zlib's C API is the one pointer interface left here: the `z_stream` stays at one
/// heap address from `inflateInit_` to `inflateEnd` (zlib keeps a pointer back to it
/// and refuses a moved stream, inflate.c inflateStateCheck), and its `next_in` /
/// `next_out` point into Swift arrays only while one `inflate` call runs.
final class ZlibStream {
    private let stream: UnsafeMutablePointer<z_stream>
    private var output = [UInt8](repeating: 0, count: 1 << 16)

    init() throws {
        // SAFETY: one z_stream allocated and initialized here. It becomes `self.stream`
        // only after inflateInit_ succeeds; a failure frees it below, so deinit (which
        // frees `self.stream`) never sees a stream this path freed.
        let stream = unsafe UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        // SAFETY: `stream` is the allocation above, not yet initialized.
        unsafe stream.initialize(to: z_stream())
        // SAFETY: inflateInit_ fills the initialized stream at its final address; it
        // reads the NUL-terminated version string Swift passes for this call only.
        // z_stream is about 112 bytes: the conversion is exact.
        let status = unsafe inflateInit_(stream, ZLIB_VERSION, Int32(truncatingIfNeeded: MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            // SAFETY: inflateInit_ failed, so zlib holds no state; the local stream is freed once here.
            unsafe stream.deinitialize(count: 1)
            // SAFETY: as above.
            unsafe stream.deallocate()
            throw RFBError.protocolViolation("zlib init \(status)")
        }
        // SAFETY: hands the initialized stream to this object, which frees it in deinit.
        self.stream = unsafe stream
    }

    deinit {
        // SAFETY: the stream was initialized by a successful inflateInit_ in init and is
        // ended, deinitialized and freed once, here.
        unsafe inflateEnd(stream)
        // SAFETY: as above: the one initialized z_stream of this object.
        unsafe stream.deinitialize(count: 1)
        // SAFETY: as above: freed once, after inflateEnd released zlib's state.
        unsafe stream.deallocate()
    }

    /// Inflates every byte of `input`; returns all the output it produced.
    /// Throws once the output passes `limit` (a decompression bomb).
    func inflate(_ input: ArraySlice<UInt8>, limit: Int) throws -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(min(limit, max(input.count * 4, 1 << 16)))
        guard !input.isEmpty else { return result }
        try input.withUnsafeBufferPointer { source in
            // SAFETY: next_in points at `source`, valid for this closure; zlib reads at most
            // avail_in = source.count bytes from it and never writes through it (the
            // mutable pointer is only zlib's declared type), and the defer clears it
            // before the closure returns, also when it throws.
            unsafe stream.pointee.next_in = UnsafeMutablePointer(mutating: source.baseAddress)
            // SAFETY: the live stream (see the type's note); a field write.
            unsafe stream.pointee.avail_in = uInt(source.count)
            // SAFETY: the live stream; no pointer into `source` outlives the closure.
            defer { unsafe stream.pointee.next_in = nil }
            let capacity = output.count
            while true {
                let produced: Int = try output.withUnsafeMutableBufferPointer { out in
                    // SAFETY: next_out points at `out`, valid for this closure, and zlib writes
                    // at most avail_out = capacity = out.count bytes through it; the defer
                    // clears it before the closure returns.
                    unsafe stream.pointee.next_out = out.baseAddress
                    // SAFETY: the live stream; a field write.
                    unsafe stream.pointee.avail_out = uInt(capacity)
                    // SAFETY: the live stream; no pointer into `out` outlives the closure.
                    defer { unsafe stream.pointee.next_out = nil }
                    // SAFETY: the stream is initialized and its in/out windows are set above.
                    let status = unsafe zlib.inflate(stream, Z_SYNC_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                        throw RFBError.protocolViolation("zlib inflate \(status)")
                    }
                    // SAFETY: the live stream; a field read.
                    return capacity - Int(truncatingIfNeeded: unsafe stream.pointee.avail_out)
                }
                result.append(contentsOf: output.prefix(produced))
                guard result.count <= limit else { throw RFBError.protocolViolation("compressed rectangle inflates past \(limit) bytes") }
                // SAFETY: the live stream; a field read.
                let inputLeft = unsafe stream.pointee.avail_in
                // SAFETY: the live stream; a field read.
                let outputLeft = unsafe stream.pointee.avail_out
                guard produced > 0, inputLeft > 0 || outputLeft == 0 else { break }
            }
        }
        return result
    }
}
