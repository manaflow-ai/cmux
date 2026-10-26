import Foundation
import Darwin
import CmuxNextCompat

/// An anonymous (already unlinked) temp file.
final class TempOutput {
    let handle: FileHandle

    init() throws {
        var template = Array((NSTemporaryDirectory() + "cmux-next-proc.XXXXXX").utf8CString)
        // The template array is never empty; without a base address mkstemp's failure path runs.
        let fd = template.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { errno = EINVAL; return -1 }
            return mkstemp(base)
        }
        guard fd >= 0 else { throw DaemonError.launchFailed("mkstemp: \(String(cString: strerror(errno)))") }
        template.withUnsafeBufferPointer { buffer in if let base = buffer.baseAddress { _ = blockingUnlink(base) } }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func contents() -> Data {
        let fd = handle.fileDescriptor
        let size = lseek(fd, 0, SEEK_END)
        guard size > 0 else { return Data() }
        // off_t is 64-bit, as Int is on every platform cmux runs on: exact.
        let byteCount = Int(clamping: size)
        var data = Data(count: byteCount)
        let count = data.withUnsafeMutableBytes { blockingPread(fd, $0.baseAddress, byteCount, 0) }
        return count > 0 ? data.prefix(count) : Data()
    }
}
