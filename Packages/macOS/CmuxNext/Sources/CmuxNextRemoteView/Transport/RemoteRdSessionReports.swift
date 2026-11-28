/// Where one viewer session's report goes when it ends (goal screen-share-fast: real sessions feed
/// the present-time board, not only the nightly probe). The report is the Rust core's
/// `cmux.rd-session-report/1` JSON: connect to first frame, and the session's display-to-glass
/// and Present p50/p95, numbers only. Whoever builds a transport passes one in (the app: crash
/// reporting, which sends only while anonymous telemetry is on); the default drops every report.
/// A value with no shared state: the transport calls it on its own queue, no actor hop.
public nonisolated struct RemoteRdSessionReports: Sendable {
    private let sink: (@Sendable (String) -> Void)?

    /// Reports go nowhere (tests, debug hosts, remote browser tabs).
    public init() { sink = nil }

    /// Reports go to `sink`, called on the transport's queue once per ended session.
    public init(_ sink: @escaping @Sendable (String) -> Void) { self.sink = sink }

    /// Sends one ended session's report. Sessions that never put a frame on glass are left out
    /// (a failed connect has no present time).
    func send(_ report: String) {
        guard let sink, !report.contains("\"frames_presented\":0,") else { return }
        sink(report)
    }
}
