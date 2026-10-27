public import Foundation

/// Why a Files operation did not happen.
public enum FileBrowserError: Error, Sendable, Equatable {
    /// The folder could not be opened or read (`errno` given).
    case unreadable(URL, Int32)
    /// A name is not allowed: empty, `.`/`..`, or with `/` or NUL.
    case invalidName(String)
    /// Rename Items' Format start number is so large that an item's number does not fit in an `Int`.
    case renameNumberTooLarge
    /// An item with the name exists where the operation would put one.
    case exists(URL)
    /// The item is gone.
    case missing(URL)
    /// A file system call failed (message from the system).
    case failed(String)
    /// The person stopped the operation.
    case cancelled
}

extension FileBrowserError {
    /// ``failed(_:)`` with the system's text for a POSIX error number.
    static func posix(_ code: Int32) -> FileBrowserError {
        .failed(systemText(code))
    }

    /// The system's text for a POSIX error number, as `strerror` gives it, read with the thread-safe
    /// `strerror_r` into a buffer this call owns (Chromium's `safe_strerror`,
    /// base/posix/safe_strerror.cc): `strerror` may return one static buffer another thread overwrites.
    /// CmuxNextDaemon's `POSIXErrorText` does the same; this module does not link the daemon.
    static func systemText(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        // SAFETY: strerror_r writes at most buffer.count bytes, the NUL included, into the array's own storage,
        // which lives for the call. On an unknown code or a short buffer it still writes a NUL-terminated text.
        _ = unsafe strerror_r(code, &buffer, buffer.count)
        let text = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return text.isEmpty ? "error \(code)" : String(decoding: text, as: UTF8.self)
    }
}
