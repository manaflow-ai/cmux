import Darwin
import Dispatch
import Foundation

/// Reads repository-controlled Git config files through bounded regular-file I/O.
nonisolated struct GitConfigFileReader: Sendable {
    /// The result distinguishes an oversized file from an unavailable path.
    enum ReadResult: Sendable {
        case contents(String, consumedByteCount: Int)
        case oversized(consumedByteCount: Int)
        case missing
        case unavailable(consumedByteCount: Int)

        var isAvailable: Bool {
            switch self {
            case .contents, .oversized:
                return true
            case .missing, .unavailable:
                return false
            }
        }
    }

    static let defaultMaximumByteCount = 1 * 1_024 * 1_024

    /// Returns whether `url` is a local regular file without reading its body.
    func isLocalRegularFile(
        at url: URL,
        deadline: DispatchTime? = nil
    ) -> Bool {
        probeLocalPath(at: url, deadline: deadline) == mode_t(S_IFREG)
    }

    /// Returns whether `url` is a local directory without recursively probing it.
    func isLocalDirectory(
        at url: URL,
        deadline: DispatchTime? = nil
    ) -> Bool {
        probeLocalPath(at: url, deadline: deadline) == mode_t(S_IFDIR)
    }

    /// Reads one regular UTF-8 config file without following a blocking FIFO.
    func read(
        at url: URL,
        maximumByteCount: Int = Self.defaultMaximumByteCount,
        deadline: DispatchTime? = nil
    ) -> ReadResult {
        let maximumByteCount = max(0, maximumByteCount)
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            return errno == ENOENT ? .missing : .unavailable(consumedByteCount: 0)
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            return .unavailable(consumedByteCount: 0)
        }
        var filesystem = statfs()
        guard Darwin.fstatfs(descriptor, &filesystem) == 0,
              (UInt64(filesystem.f_flags) & UInt64(MNT_LOCAL)) != 0 else {
            // A regular file on a remote filesystem can block in `read` despite
            // O_NONBLOCK. Fail closed so callers retain their wall-time bound.
            return .unavailable(consumedByteCount: 0)
        }

        let chunkByteCount = 64 * 1_024
        var data = Data()
        data.reserveCapacity(min(maximumByteCount, chunkByteCount))
        var buffer = [UInt8](repeating: 0, count: chunkByteCount)
        while data.count <= maximumByteCount {
            if let deadline, deadline <= DispatchTime.now() {
                return .unavailable(consumedByteCount: data.count)
            }
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                if data.count > maximumByteCount {
                    return .oversized(consumedByteCount: data.count)
                }
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            return .unavailable(consumedByteCount: data.count)
        }

        guard let contents = String(data: data, encoding: .utf8) else {
            return .unavailable(consumedByteCount: data.count)
        }
        return .contents(contents, consumedByteCount: data.count)
    }

    /// Performs only bounded descriptor metadata operations for watcher paths.
    private func probeLocalPath(
        at url: URL,
        deadline: DispatchTime?
    ) -> mode_t? {
        guard deadline.map({ $0 > DispatchTime.now() }) ?? true else {
            return nil
        }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC
        )
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else { return nil }
        let kind = metadata.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFDIR) else { return nil }

        var filesystem = statfs()
        guard Darwin.fstatfs(descriptor, &filesystem) == 0,
              (UInt64(filesystem.f_flags) & UInt64(MNT_LOCAL)) != 0 else {
            return nil
        }
        return kind
    }
}
