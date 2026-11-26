import Foundation

/// `flush-launch-snapshot` (`launch-snapshot-flush-v1`, cmux-tui spec/commands.md): the daemon
/// writes its launch snapshot now, not after changes settle, and answers once it landed (or after
/// 1 s). The quit sends it after the last window record save, so a relaunch on the same daemon
/// draws its first frame from that save (`LaunchSnapshot`) and nothing moves when restore adopts
/// the live record.
public struct FlushLaunchSnapshotRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        /// True once the file holds the session's state as of the request.
        public var flushed: Bool?
    }

    public static let command = "flush-launch-snapshot"
    public static var requiredCapability: String? { DaemonCapability.launchSnapshotFlush.rawValue }

    public init() {}
}

extension DaemonConnection {
    /// Asks for `flush-launch-snapshot` with a 1 s limit. A daemon without `launch-snapshot-flush-v1`
    /// is not asked (`requiredCapability`); a failure costs only that a relaunch's first frame may
    /// draw the older snapshot, as before.
    public func flushLaunchSnapshot() async {
        _ = try? await request(FlushLaunchSnapshotRequest(), timeout: .seconds(1))
    }
}
