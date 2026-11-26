import CmuxNextCompat

/// Where each ended viewer session's report goes (goal screen-share-fast: real sessions feed the
/// present-time board, not only the nightly probe). The report is the Rust core's
/// `cmux.rd-session-report/1` JSON: connect to first frame, and the session's display-to-glass
/// and Present p50/p95, numbers only. The app installs one sink (crash reporting, which sends only
/// while anonymous telemetry is on); with none installed a report is dropped.
public struct RemoteRdSessionReports {
    public init() {}
    private static let sink = Mutex<(@Sendable (String) -> Void)?>(nil)

    /// Installs the sink every later session end reports to (the newest call wins).
    public static func install(_ send: @escaping @Sendable (String) -> Void) {
        sink.withLock { $0 = send }
    }

    /// Sends one ended session's report to the installed sink. Sessions that never put a frame on
    /// glass are left out (a failed connect has no present time).
    static func send(_ report: String) {
        guard !report.contains("\"frames_presented\":0,") else { return }
        let send = sink.withLock { $0 }
        send?(report)
    }
}
