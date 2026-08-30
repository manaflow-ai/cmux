import Darwin
import Dispatch
import Foundation

/// Reads a Git index through a bounded, stable regular-file descriptor.
nonisolated struct GitIndexDataReader: Sendable {
    private static let readChunkByteCount = 64 * 1_024

    /// One stable-descriptor read, retaining a valid header even when the body
    /// is above the caller's byte budget.
    struct ReadResult: Sendable {
        let exists: Bool
        let header: GitIndexHeaderSummary?
        let data: Data?
    }

    /// Reads at most `maximumByteCount` bytes from a local regular index file.
    func read(
        at url: URL,
        maximumByteCount: Int,
        deadline: DispatchTime? = nil
    ) -> ReadResult {
        let maximumByteCount = max(0, maximumByteCount)
        guard !WorkspaceChangesCancellationSignal.isCurrentCancelled,
              deadline.map({ $0 > DispatchTime.now() }) ?? true else {
            return ReadResult(exists: false, header: nil, data: nil)
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            return ReadResult(exists: false, header: nil, data: nil)
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_size >= 0,
              metadata.st_size <= Int64(Int.max) else {
            return ReadResult(exists: true, header: nil, data: nil)
        }
        var filesystem = statfs()
        guard Darwin.fstatfs(descriptor, &filesystem) == 0,
              (UInt64(filesystem.f_flags) & UInt64(MNT_LOCAL)) != 0 else {
            return ReadResult(exists: true, header: nil, data: nil)
        }

        let expectedByteCount = Int(metadata.st_size)
        guard let header = readHeader(
            descriptor: descriptor,
            fileByteCount: expectedByteCount,
            deadline: deadline
        ) else {
            return ReadResult(exists: true, header: nil, data: nil)
        }
        guard expectedByteCount <= maximumByteCount else {
            return ReadResult(exists: true, header: header, data: nil)
        }
        var data = Data()
        data.reserveCapacity(expectedByteCount)
        var buffer = [UInt8](repeating: 0, count: Self.readChunkByteCount)
        var offset: off_t = 0
        while offset < metadata.st_size {
            guard !WorkspaceChangesCancellationSignal.isCurrentCancelled,
                  deadline.map({ $0 > DispatchTime.now() }) ?? true else {
                return ReadResult(exists: true, header: header, data: nil)
            }
            let requested = min(
                buffer.count,
                Int(metadata.st_size - offset)
            )
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.pread(descriptor, bytes.baseAddress, requested, offset)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                offset += off_t(count)
                continue
            }
            if count < 0, errno == EINTR { continue }
            return ReadResult(exists: true, header: header, data: nil)
        }
        guard data.count == expectedByteCount else {
            return ReadResult(exists: true, header: header, data: nil)
        }
        return ReadResult(exists: true, header: header, data: data)
    }

    private func readHeader(
        descriptor: Int32,
        fileByteCount: Int,
        deadline: DispatchTime?
    ) -> GitIndexHeaderSummary? {
        guard fileByteCount >= 32,
              !WorkspaceChangesCancellationSignal.isCurrentCancelled,
              deadline.map({ $0 > DispatchTime.now() }) ?? true else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: 12)
        var count: Int = -1
        repeat {
            count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.pread(descriptor, buffer.baseAddress, buffer.count, 0)
            }
        } while count < 0 && errno == EINTR
        guard count == bytes.count,
              bytes[0] == 0x44, bytes[1] == 0x49,
              bytes[2] == 0x52, bytes[3] == 0x43 else {
            return nil
        }
        let version = (UInt32(bytes[4]) << 24)
            | (UInt32(bytes[5]) << 16)
            | (UInt32(bytes[6]) << 8)
            | UInt32(bytes[7])
        guard version == 2 || version == 3 || version == 4 else { return nil }
        let entryCount = (UInt32(bytes[8]) << 24)
            | (UInt32(bytes[9]) << 16)
            | (UInt32(bytes[10]) << 8)
            | UInt32(bytes[11])
        return GitIndexHeaderSummary(
            entryCount: Int(entryCount),
            fileByteCount: Int64(fileByteCount)
        )
    }
}
