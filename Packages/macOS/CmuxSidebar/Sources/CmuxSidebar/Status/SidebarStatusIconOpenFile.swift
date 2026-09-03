import Darwin
import Foundation

/// Owns one validated status-icon descriptor until its metadata is consumed or its body is read.
final class SidebarStatusIconOpenFile {
    /// Descriptor metadata used to identify an unchanged file without retaining its encoded body.
    struct Metadata: Hashable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
    }

    let metadata: Metadata
    private let descriptor: Int32

    init(descriptor: Int32, metadata: stat) {
        self.descriptor = descriptor
        self.metadata = Metadata(
            device: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(truncatingIfNeeded: metadata.st_ino),
            size: Int64(metadata.st_size),
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            changeSeconds: Int64(metadata.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
    }

    deinit {
        Darwin.close(descriptor)
    }

    /// Reads through the already validated descriptor, including one sentinel byte for growth races.
    func data(maximumByteCount: Int) -> Data? {
        guard maximumByteCount > 0, maximumByteCount < Int.max else { return nil }

        var data = Data()
        data.reserveCapacity(Int(metadata.size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, maximumByteCount + 1))
        while data.count <= maximumByteCount {
            let remaining = maximumByteCount + 1 - data.count
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, min(bytes.count, remaining))
            }
            if bytesRead == 0 { break }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                return nil
            }
            data.append(buffer, count: bytesRead)
        }
        guard !data.isEmpty, data.count <= maximumByteCount else { return nil }
        return data
    }
}
