import Darwin
import Foundation

/// Atomically replaces a regular note without following the destination entry.
struct CmuxNoteAtomicWriter {
    func write(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".cmux-note-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw CmuxNoteStoreError.pathOutsideStore(temporary.path)
        }
        var keepsTemporary = true
        defer {
            _ = Darwin.close(descriptor)
            if keepsTemporary { _ = Darwin.unlink(temporary.path) }
        }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw CmuxNoteStoreError.pathOutsideStore(destination.path)
                }
                offset += written
            }
        }
        guard Darwin.fsync(descriptor) == 0,
              Darwin.rename(temporary.path, destination.path) == 0 else {
            throw CmuxNoteStoreError.pathOutsideStore(destination.path)
        }
        keepsTemporary = false
    }
}
