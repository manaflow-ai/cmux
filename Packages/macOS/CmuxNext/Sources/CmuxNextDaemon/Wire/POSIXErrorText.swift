import Darwin

/// The text of a POSIX error number, as `strerror` gives it, read with the thread-safe `strerror_r` into a
/// buffer this call owns. Chromium formats errno the same way (`safe_strerror`, base/posix/safe_strerror.cc):
/// `strerror` may return one static buffer that another thread overwrites.
package struct POSIXErrorText: Sendable, Equatable, CustomStringConvertible {
    /// The error number (`errno`, or a code a call returned).
    package let code: Int32

    package init(_ code: Int32) {
        self.code = code
    }

    package var description: String {
        var buffer = [CChar](repeating: 0, count: Self.capacity)
        // SAFETY: strerror_r writes at most buffer.count bytes, the NUL included, into the array's own storage,
        // which lives for the call. On an unknown code or a short buffer it still writes a NUL-terminated text.
        _ = unsafe strerror_r(code, &buffer, buffer.count)
        let text = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return text.isEmpty ? "error \(code)" : String(decoding: text, as: UTF8.self)
    }

    /// The longest Darwin message (`sys_errlist`) is under 64 bytes; Chromium's buffer is 256.
    private static let capacity = 256
}
