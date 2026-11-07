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

    /// `error`'s failure; `freeBytes` is the free space on the state's volume (nil: unknown). The words and
    /// the low-space bound are cmux-daemon-launch-core's (`classify_error`); a library that does not answer
    /// reads a plain failure.
    init(_ error: any Error, freeBytes: UInt64?) {
        self = DaemonStartClassification(error, freeBytes: freeBytes)?.failure
            ?? DaemonStartFailure(kind: .failed, detail: String(describing: error))
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

extension DaemonStartFailure: Decodable {
    private enum CodingKeys: String, CodingKey { case kind, detail }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        self.init(kind: Kind(rawValue: kind) ?? .failed, detail: try container.decode(String.self, forKey: .detail))
    }
}

/// The app's daemon error as the launch rules read it (cmux-daemon-launch-core `ErrorInput`): its kind
/// (`restore_timeout`, `timed_out`, `launch_failed`, `command` or `other`), the words they look at, and the
/// error as the launcher saw it (Copy Details, `debug.daemon`).
struct DaemonLaunchErrorInput: Encodable {
    var kind: String
    var detail: String?
    var message: String?
    var reason: String?
    var description: String

    init(_ error: any Error) {
        description = String(describing: error)
        switch error as? DaemonError {
        case .sessionRestoreTimedOut?: kind = "restore_timeout"
        case .timedOut?: kind = "timed_out"
        case .launchFailed(let text)?:
            kind = "launch_failed"
            detail = text
        case .command(_, let text, _, let details, _)?:
            kind = "command"
            message = text
            if case .object(let fields)? = details { reason = fields["reason"]?.stringValue }
        default: kind = "other"
        }
    }
}

/// What the launch rules read in one ensure's error (`classify_error`).
struct DaemonStartClassification: Decodable {
    /// It failed the way a stuck owner makes it fail.
    var stuck: Bool
    /// The volume under the daemon's state is full, by the error's own words.
    var diskFull: Bool
    /// What the unresponsive-owner watch gets.
    var watch: UnresponsiveOwnerWatch.Ensure
    var failure: DaemonStartFailure

    init?(_ error: any Error, freeBytes: UInt64? = nil) {
        struct Request: Encodable { var error: DaemonLaunchErrorInput, freeBytes: UInt64? }
        guard let reply = DaemonLaunchRules.call("classify_error", Request(error: DaemonLaunchErrorInput(error), freeBytes: freeBytes),
                                                 as: Self.self) else { return nil }
        self = reply
    }
}

extension DaemonError {
    /// The daemon refused, or could not start, because the volume under its state is full (SQLite's
    /// "database or disk is full", ENOSPC; restore fuzz h2 and h3). The person reads that reason in
    /// their language; a scripted caller still gets this error.
    public var isDiskFull: Bool {
        DaemonStartClassification(self)?.diskFull ?? false
    }
}
