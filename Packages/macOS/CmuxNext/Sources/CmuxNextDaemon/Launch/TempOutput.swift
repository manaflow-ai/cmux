import Foundation
import Darwin
import CmuxNextCompat

/// An anonymous (already unlinked) temp file.
final class TempOutput {
    let handle: FileHandle

    init() throws {
        var template = Array((NSTemporaryDirectory() + "cmux-next-proc.XXXXXX").utf8CString)
        // The template array is never empty; without a base address mkstemp's failure path runs.
        // SAFETY: mkstemp rewrites the XXXXXX in place inside the NUL-terminated template, the array's own
        // storage, which the closure lends for the call.
        let fd = unsafe template.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = unsafe buffer.baseAddress else { errno = EINVAL; return -1 }
            return unsafe mkstemp(base)
        }
        guard fd >= 0 else { throw DaemonError.launchFailed("mkstemp: \(POSIXErrorText(errno))") }
        // SAFETY: unlink reads the template, now the NUL-terminated path mkstemp created, lent for the call.
        unsafe template.withUnsafeBufferPointer { buffer in if let base = unsafe buffer.baseAddress { _ = unsafe blockingUnlink(base) } }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func contents() -> Data {
        let fd = handle.fileDescriptor
        let size = lseek(fd, 0, SEEK_END)
        guard size > 0 else { return Data() }
        // off_t is 64-bit, as Int is on every platform cmux runs on: exact.
        let byteCount = Int(clamping: size)
        var data = Data(count: byteCount)
        // SAFETY: pread writes at most byteCount bytes, the size of `data`, into its storage, lent for the call.
        let count = unsafe data.withUnsafeMutableBytes { unsafe blockingPread(fd, $0.baseAddress, byteCount, 0) }
        return count > 0 ? data.prefix(count) : Data()
    }
}
