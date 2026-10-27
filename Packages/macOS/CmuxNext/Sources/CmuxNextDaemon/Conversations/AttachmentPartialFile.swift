import CmuxNextCompat
import Darwin
import Foundation

/// One attachment read's partial file: `.<name>.<uuid>.partial` beside its
/// destination, written at offsets and moved into place only when complete,
/// so a cancelled or failed read leaves nothing. Every method blocks on the
/// disk; ``AttachmentTransfer`` calls each on a files lane, never on the
/// caller's thread.
struct AttachmentPartialFile: Sendable {
    /// The partial file.
    let url: URL
    /// Where the complete bytes go.
    let destination: URL
    private let descriptor: Int32

    /// Makes `destination`'s folder and an empty partial file in it, open for writing.
    ///
    /// - Throws: The folder's create error, or a `POSIXError` when the file does not open.
    static func create(for destination: URL) throws -> AttachmentPartialFile {
        let directory = destination.deletingLastPathComponent()
        try FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        // SAFETY: open reads the NUL-terminated file system path the URL lends for the closure.
        let descriptor = unsafe url.withUnsafeFileSystemRepresentation { path in
            unsafe path.map { unsafe blockingOpen($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644) } ?? -1
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return AttachmentPartialFile(url: url, destination: destination, descriptor: descriptor)
    }

    /// Writes all of `bytes` at `offset`.
    ///
    /// - Throws: A `POSIXError` when a write fails.
    func write(_ bytes: Data, at offset: Int) throws {
        // SAFETY: `buffer` is Data's contiguous storage, valid only inside this closure, which never lets a
        // pointer out.
        let failure: Int32? = unsafe bytes.withUnsafeBytes { buffer -> Int32? in
            var done = 0
            // SAFETY: reads only the buffer's count.
            while unsafe done < buffer.count {
                // SAFETY: 0 <= done < buffer.count, so the write starts at base + done and covers the
                // buffer.count - done bytes left, which end at the buffer's end.
                let wrote = unsafe blockingPwrite(descriptor, buffer.baseAddress.map { unsafe $0 + done }, buffer.count - done,
                                                  off_t(offset + done))
                if wrote < 0, errno == EINTR { continue }
                guard wrote > 0 else { return errno }
                done += wrote
            }
            return nil
        }
        if let failure { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
    }

    /// Flushes the bytes to the disk, closes the file and moves it to ``destination``. A file another read of
    /// the same variant placed first holds the same bytes: this one is removed and that one kept.
    ///
    /// - Throws: A `POSIXError` when the flush fails, or the move's error when nothing is at ``destination``.
    func finish() throws {
        let synced = blockingFsync(descriptor) == 0
        let syncError = errno
        close(descriptor)
        guard synced else {
            try? FileManager.checked.removeItem(at: url)
            throw POSIXError(POSIXErrorCode(rawValue: syncError) ?? .EIO)
        }
        do {
            try FileManager.checked.moveItem(at: url, to: destination)
        } catch {
            try? FileManager.checked.removeItem(at: url)
            guard FileManager.checked.fileExists(atPath: destination.path) else { throw error }
        }
    }

    /// Closes and removes the partial file (a read that failed or was cancelled).
    func discard() {
        close(descriptor)
        try? FileManager.checked.removeItem(at: url)
    }
}
