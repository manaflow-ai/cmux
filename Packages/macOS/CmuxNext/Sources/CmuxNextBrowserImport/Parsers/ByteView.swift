/// Bytes read in place by a parser (a password CSV, an export archive), lent
/// for one call by their owner (`SecretBytes.withUnsafeBytes`) so a password
/// is never copied out of its locked buffer. Every read is bounds-checked, as
/// Chromium's base::span (base/containers/span.h): a byte past the end reads
/// as 0 and a range outside the view is nil, so a length a file lies about
/// never reads outside the bytes. A damaged file is an answer, not a trap.
///
/// Memory safety: `bytes` is valid only inside the closure that lent it. A
/// view is made there (`init` is `@unsafe` for that reason), passed down by
/// value, and never stored or returned past that closure; the parsers here
/// return values copied out of it.
@safe
struct ByteView: RandomAccessCollection {
    private let bytes: UnsafeRawBufferPointer

    @unsafe init(_ bytes: UnsafeRawBufferPointer) {
        unsafe self.bytes = bytes
    }

    var startIndex: Int { 0 }
    // SAFETY: reads the lent buffer's count, not its bytes.
    var endIndex: Int { unsafe bytes.count }

    subscript(index: Int) -> UInt8 {
        guard index >= 0, index < endIndex else { return 0 }
        // SAFETY: 0 <= index < bytes.count (checked above), inside the lent bytes.
        return unsafe bytes[index] // decode-trap-allow: 0 <= index < count checked on the line above
    }

    /// The bytes in `range` as a view of their own (indices from 0), or nil when the range is not
    /// inside this view.
    func view(_ range: Range<Int>) -> ByteView? {
        guard range.lowerBound >= 0, range.upperBound <= endIndex else { return nil }
        // SAFETY: `range` is inside the lent bytes (checked above), and the new view is lent for no
        // longer than this one (see the type).
        return unsafe ByteView(UnsafeRawBufferPointer(rebasing: bytes[range])) // decode-trap-allow: range inside, checked above
    }

    /// The bytes decoded as UTF-8 (a bad sequence becomes U+FFFD); the String is a copy.
    var text: String {
        // SAFETY: decodes the view's bytes, inside the lent range, during this call only.
        unsafe String(decoding: bytes, as: UTF8.self)
    }

    /// A little-endian field at `offset`; 0 when it does not fit in the view.
    func littleEndian16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset <= endIndex - 2 else { return 0 }
        return UInt16(truncatingIfNeeded: byte(offset)) | UInt16(truncatingIfNeeded: byte(offset + 1)) << 8
    }

    /// A little-endian field at `offset`; 0 when it does not fit in the view.
    func littleEndian32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset <= endIndex - 4 else { return 0 }
        return UInt32(truncatingIfNeeded: littleEndian16(offset)) | UInt32(truncatingIfNeeded: littleEndian16(offset + 2)) << 16
    }

    /// The byte at `index`; 0 outside the view (the subscript's answer, named so a reader's call is not an index).
    func byte(_ index: Int) -> UInt8 {
        self[index] // decode-trap-allow: ByteView's subscript reads 0 outside the view, it never traps
    }

    /// Lends the view's bytes to a C call (a decompressor) for the length of `body`.
    @safe func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        // SAFETY: the lent bytes are valid for this call (see the type), and `body` is not escaping,
        // so it cannot keep them.
        try unsafe body(bytes)
    }
}
