#if canImport(Compression)
import Compression
#else
import CZlib
#endif

/// Raw DEFLATE (RFC 1951, no zlib or gzip framing), what a zip entry holds: Compression's COMPRESSION_ZLIB on
/// Apple platforms, zlib with a negative window size where there is no Compression (the Linux tier).
enum RawDeflate {
    /// Inflates `count` bytes at `source` into the `capacity` bytes at `destination`: how many it wrote (as many
    /// as fit when the stream holds more, fewer when it ends early), or nil when nothing decodes. A caller that
    /// knows the size compares it, as Compression gives no other signal.
    @unsafe static func inflate(_ source: UnsafePointer<UInt8>, count: Int, into destination: UnsafeMutablePointer<UInt8>,
                                capacity: Int) -> Int? {
        guard count > 0, capacity > 0 else { return nil }
        #if canImport(Compression)
        // SAFETY: the decoder reads at most `count` bytes at `source` and writes at most `capacity` at
        // `destination`, the counts the caller lends; a nil scratch buffer makes it allocate its own.
        let written = unsafe compression_decode_buffer(destination, capacity, source, count, nil, COMPRESSION_ZLIB)
        return written > 0 ? written : nil
        #else
        guard let availableIn = uInt(exactly: count), let availableOut = uInt(exactly: capacity) else { return nil }
        // SAFETY (each `unsafe` below): `stream` is a local that holds only the caller's two buffers, live for this
        // call, and zlib's own state, which inflateEnd frees before it goes out of scope. inflateInit2_ reads the
        // NUL-terminated version Swift makes for the call; zlib only reads through next_in, writes at most
        // avail_out bytes at next_out and reads at most avail_in at next_in.
        var stream = unsafe z_stream()
        guard unsafe inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(clamping: MemoryLayout<z_stream>.size)) == Z_OK
        else { return nil }
        defer { unsafe inflateEnd(&stream) }
        unsafe stream.next_in = UnsafeMutablePointer(mutating: source)
        unsafe stream.avail_in = availableIn
        unsafe stream.next_out = destination
        unsafe stream.avail_out = availableOut
        // Z_BUF_ERROR is a full buffer or a stream that ends early: the bytes so far are the answer, as Compression
        // gives them. Any other result but the stream's end is bad data.
        let result = unsafe CZlib.inflate(&stream, Z_FINISH)
        guard result == Z_STREAM_END || result == Z_BUF_ERROR || result == Z_OK,
              let written = unsafe Int(exactly: stream.total_out), written > 0 else { return nil }
        return written
        #endif
    }
}
