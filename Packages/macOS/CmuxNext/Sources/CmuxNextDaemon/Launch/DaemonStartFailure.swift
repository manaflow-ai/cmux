import Darwin
import Foundation

/// Why the launcher's last `server ensure` failed: what the person reads beside "Restart cmux-tui"
/// while no daemon runs (restore fuzz h2). A full disk is told apart, because only freeing space
/// fixes it and the app then starts the daemon again by itself.
public struct DaemonStartFailure: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// The volume under the daemon's state has no space left, or the start said so.
        case diskFull = "disk_full"
        /// Any other failure.
        case failed
    }

    public let kind: Kind
    /// The failure as the launcher saw it, for Copy Details and `debug.daemon`.
    public let detail: String

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    public var isDiskFull: Bool { kind == .diskFull }

    /// Less free space than this on the state's volume reads as a full disk: SQLite and the
    /// daemon's logs fail well before the last byte, so `server ensure` then fails with no word
    /// about space ("the detached session owner did not become ready", restore fuzz h2).
    static let lowSpaceBytes: UInt64 = 64 << 20

    /// The words a failure caused by a full disk carries (ENOSPC, SQLite's SQLITE_FULL).
    private static let diskFullMarkers = ["no space left on device", "os error 28", "enospc", "disk is full", "disk full"]

    /// Whether `text` (an error's words) says the disk is full.
    static func saysDiskFull(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return diskFullMarkers.contains { lowered.contains($0) }
    }

    /// `error`'s failure; `freeBytes` is the free space on the state's volume (nil: unknown).
    init(_ error: any Error, freeBytes: UInt64?) {
        let detail = String(describing: error)
        let lowSpace = freeBytes.map { $0 < Self.lowSpaceBytes } ?? false
        self.init(kind: Self.saysDiskFull(detail) || lowSpace ? .diskFull : .failed, detail: detail)
    }

    /// Free bytes on the volume that holds `url`, or on its nearest existing parent; nil when
    /// none can be read. One `statfs` per folder: only after a failed ensure, off the main actor.
    static func freeBytes(at url: URL) -> UInt64? {
        var path = url.path
        for _ in 0..<64 {
            var info = statfs()
            if statfs(path, &info) == 0 {
                let (bytes, overflow) = info.f_bavail.multipliedReportingOverflow(by: UInt64(truncatingIfNeeded: info.f_bsize))
                return overflow ? .max : bytes
            }
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != path else { return nil }
            path = parent
        }
        return nil
    }
}

extension DaemonError {
    /// The daemon refused, or could not start, because the volume under its state is full (SQLite's
    /// "database or disk is full", ENOSPC; restore fuzz h2 and h3). The person reads that reason in
    /// their language; a scripted caller still gets this error.
    public var isDiskFull: Bool {
        switch self {
        case .command(_, let message, _, let details, _):
            if DaemonStartFailure.saysDiskFull(message) { return true }
            guard case .object(let fields)? = details, let reason = fields["reason"]?.stringValue else { return false }
            return DaemonStartFailure.saysDiskFull(reason)
        case .launchFailed(let detail):
            return DaemonStartFailure.saysDiskFull(detail)
        default:
            return false
        }
    }
}
