import Foundation
import Darwin

/// Bounded, no-symlink reader for project-controlled note metadata files.
struct CmuxNoteIndexDataReader: Sendable {
    let maxBytes: Int64

    func readIfPresent(atPath path: String) throws -> Data? {
        var entryInfo = stat()
        if Darwin.lstat(path, &entryInfo) != 0 {
            if errno == ENOENT {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(fd) }

        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: path])
        }
        guard info.st_size >= 0, info.st_size <= maxBytes else {
            throw CocoaError(.fileReadTooLarge, userInfo: [NSFilePathErrorKey: path])
        }

        var remaining = Int(info.st_size)
        guard remaining > 0 else { return Data() }

        var data = Data()
        data.reserveCapacity(remaining)
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, remaining))
        while remaining > 0 {
            let chunkSize = min(buffer.count, remaining)
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress, chunkSize)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if bytesRead == 0 { break }
            data.append(contentsOf: buffer.prefix(bytesRead))
            remaining -= bytesRead
        }
        return data
    }
}
