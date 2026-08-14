import Darwin
import Foundation

enum GitMetadataSafetyLimits {
    static let directFileStatusEntryCount = 4_096
    static let directFileStatusDurationMilliseconds = 100
    static let directFileStatusDuration: Duration = .milliseconds(directFileStatusDurationMilliseconds)
    static let directIndexByteCount = 32 * 1_024 * 1_024
    static let trackedEventPathCount = 200_000
    static let submoduleDepth = 4
    static let gitStatusWallTime: TimeInterval = 2
    static let filteredWorkTreeEventThrottle: Duration = .milliseconds(250)
    static let unfilteredWorkTreeEventThrottleSeconds = 30
    static let unfilteredWorkTreeEventThrottle: Duration = .seconds(
        unfilteredWorkTreeEventThrottleSeconds
    )
}

enum GitMetadataDegradationReason: Hashable, Sendable, CustomStringConvertible {
    case trackedEntryLimit(count: Int, limit: Int)
    case indexByteLimit(count: Int64, limit: Int)
    case directScanDuration(milliseconds: Int)

    var description: String {
        switch self {
        case .trackedEntryLimit(let count, let limit):
            return "tracked-entry-limit count=\(count) limit=\(limit)"
        case .indexByteLimit(let count, let limit):
            return "index-byte-limit bytes=\(count) limit=\(limit)"
        case .directScanDuration(let milliseconds):
            return "direct-scan-duration limitMs=\(milliseconds)"
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
        let descriptor = Darwin.open(indexPath, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0, status.st_size >= 12 else {
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
