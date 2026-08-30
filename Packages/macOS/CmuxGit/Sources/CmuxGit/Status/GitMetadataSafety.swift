import Darwin
import Foundation

/// Injectable budgets that keep Git metadata inspection and event handling bounded.
struct GitMetadataSafetyConfiguration: Sendable {
    let directFileStatusEntryCount: Int
    let directFileStatusDurationMilliseconds: Int
    let directIndexByteCount: Int
    let trackedEventPathCount: Int
    let submoduleDepth: Int
    let gitStatusWallTime: TimeInterval
    let filteredWorkTreeEventThrottle: Duration
    let unfilteredWorkTreeEventThrottleSeconds: Int

    var directFileStatusDuration: Duration {
        .milliseconds(directFileStatusDurationMilliseconds)
    }

    var unfilteredWorkTreeEventThrottle: Duration {
        .seconds(unfilteredWorkTreeEventThrottleSeconds)
    }

    /// Creates a safety budget; defaults are the production large-repository limits.
    init(
        directFileStatusEntryCount: Int = 4_096,
        directFileStatusDurationMilliseconds: Int = 100,
        directIndexByteCount: Int = 32 * 1_024 * 1_024,
        trackedEventPathCount: Int = 200_000,
        submoduleDepth: Int = 4,
        gitStatusWallTime: TimeInterval = 2,
        filteredWorkTreeEventThrottle: Duration = .milliseconds(250),
        unfilteredWorkTreeEventThrottleSeconds: Int = 30
    ) {
        self.directFileStatusEntryCount = directFileStatusEntryCount
        self.directFileStatusDurationMilliseconds = directFileStatusDurationMilliseconds
        self.directIndexByteCount = directIndexByteCount
        self.trackedEventPathCount = trackedEventPathCount
        self.submoduleDepth = submoduleDepth
        self.gitStatusWallTime = gitStatusWallTime
        self.filteredWorkTreeEventThrottle = filteredWorkTreeEventThrottle
        self.unfilteredWorkTreeEventThrottleSeconds = unfilteredWorkTreeEventThrottleSeconds
    }
}

enum GitMetadataDegradationReason: Hashable, Sendable, CustomStringConvertible {
    case trackedEntryLimit(count: Int, limit: Int)
    case indexByteLimit(count: Int64, limit: Int)
    case directScanDuration(milliseconds: Int)
    case submoduleReferenceBackend
    case unreadableIndex

    var description: String {
        switch self {
        case .trackedEntryLimit(let count, let limit):
            return "tracked-entry-limit count=\(count) limit=\(limit)"
        case .indexByteLimit(let count, let limit):
            return "index-byte-limit bytes=\(count) limit=\(limit)"
        case .directScanDuration(let milliseconds):
            return "direct-scan-duration limitMs=\(milliseconds)"
        case .submoduleReferenceBackend:
            return "submodule-reference-backend"
        case .unreadableIndex:
            return "unreadable-index"
        }
    }
}

struct GitIndexHeaderSummary: Sendable {
    let entryCount: Int
    let fileByteCount: Int64
}

extension GitMetadataService {
    /// Blocking `lstat` and fallback-process work never occupies Swift's
    /// cooperative executor. The sidebar's process-wide probe limiter bounds
    /// callers; this queue only provides the correct blocking-I/O execution lane.
    nonisolated static let blockingStatusQueue = DispatchQueue(
        label: "com.cmux.git-metadata-status",
        qos: .utility,
        attributes: .concurrent
    )

    /// Joins an already-normalized repository root with a validated relative
    /// index path. Unlike Foundation URL composition, this performs no hidden
    /// filesystem probes and is safe in per-entry loops.
    nonisolated static func joinedPath(root: String, relativePath: String) -> String {
        root.hasSuffix("/") ? root + relativePath : root + "/" + relativePath
    }

    nonisolated static func gitIndexHeaderSummary(indexPath: String) -> GitIndexHeaderSummary? {
        let descriptor = Darwin.open(indexPath, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size >= 12 else {
            return nil
        }
        var filesystem = statfs()
        guard Darwin.fstatfs(descriptor, &filesystem) == 0,
              (UInt64(filesystem.f_flags) & UInt64(MNT_LOCAL)) != 0 else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: 12)
        let bytesRead = bytes.withUnsafeMutableBytes { buffer in
            Darwin.pread(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard bytesRead == bytes.count,
              bytes[0] == 0x44, bytes[1] == 0x49,
              bytes[2] == 0x52, bytes[3] == 0x43 else {
            return nil
        }
        let version = readBigEndianUInt32(bytes, at: 4)
        guard version == 2 || version == 3 || version == 4 else { return nil }
        return GitIndexHeaderSummary(
            entryCount: Int(readBigEndianUInt32(bytes, at: 8)),
            fileByteCount: status.st_size
        )
    }
}
