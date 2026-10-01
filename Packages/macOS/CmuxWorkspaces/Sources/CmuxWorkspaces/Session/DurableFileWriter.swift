import Darwin
import Foundation

/// Replaces a file so the new contents survive power loss or a kernel panic.
///
/// `Data.write(options: .atomic)` renames a temp file into place but never
/// flushes it, so after a power cut the rename can be on disk while the data
/// is not, or neither is. This writes a temp file in the destination's
/// directory, flushes it to the platter with `F_FULLFSYNC` (plain `fsync` on
/// macOS leaves it in the drive cache), renames it over the destination and
/// flushes the directory so the rename itself is durable.
enum DurableFileWriter {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try writeAndFlush(data, to: temporaryURL)
            try posixCall(path: url.path) {
                temporaryURL.withUnsafeFileSystemRepresentation { source in
                    url.withUnsafeFileSystemRepresentation { destination in
                        guard let source, let destination else { return -1 }
                        return Darwin.rename(source, destination)
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        flushDirectory(directory)
    }

    private static func writeAndFlush(_ data: Data, to url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600) } ?? -1
        }
        guard descriptor >= 0 else { throw posixError(path: url.path) }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError(path: url.path)
                }
                offset += written
            }
        }
        // Filesystems without F_FULLFSYNC (network, some FUSE) fall back to fsync.
        if Darwin.fcntl(descriptor, F_FULLFSYNC) != 0 {
            try posixCall(path: url.path) { Darwin.fsync(descriptor) }
        }
    }

    /// Best effort: the rename is already visible; this only orders it on disk.
    private static func flushDirectory(_ directory: URL) {
        let descriptor = directory.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { return }
        _ = Darwin.fsync(descriptor)
        Darwin.close(descriptor)
    }

    private static func posixCall(path: String, _ body: () -> Int32) throws {
        while body() != 0 {
            if errno == EINTR { continue }
            throw posixError(path: path)
        }
    }

    private static func posixError(path: String) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
    }
}
