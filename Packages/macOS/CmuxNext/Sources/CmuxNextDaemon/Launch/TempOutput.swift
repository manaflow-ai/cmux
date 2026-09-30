import Foundation
import Darwin

/// An anonymous (already unlinked) temp file.
final class TempOutput {
    let handle: FileHandle

    init() throws {
        var template = Array((NSTemporaryDirectory() + "cmux-next-proc.XXXXXX").utf8CString)
        // crash-allow: the template array is never empty, so baseAddress is set.
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { throw DaemonError.launchFailed("mkstemp: \(String(cString: strerror(errno)))") }
        // crash-allow: the template array is never empty, so baseAddress is set.
        template.withUnsafeBufferPointer { _ = unlink($0.baseAddress!) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func contents() -> Data {
        let fd = handle.fileDescriptor
        let size = lseek(fd, 0, SEEK_END)
        guard size > 0 else { return Data() }
        var data = Data(count: Int(size))
        let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Int(size), 0) }
        return count > 0 ? data.prefix(count) : Data()
    }
}
