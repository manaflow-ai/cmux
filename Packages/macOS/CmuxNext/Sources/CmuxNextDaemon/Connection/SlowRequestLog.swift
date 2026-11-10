public import Foundation

/// The app side of the slow request log: one record for each daemon request the app waited more than
/// 100 ms for, each request that timed out or failed, and each optimistic change that was rolled back.
///
/// This commit holds the tests and the hooks only: nothing is recorded yet.
public final class SlowRequestLog: Sendable {
    /// A request the app waited longer than this for gets a record.
    public static let slowNanoseconds: UInt64 = 100_000_000
    /// The most bytes of the file and of its one rotated copy (`.1`), each.
    public static let maxFileBytes = 1 << 20
    public static let fileName = "slow-requests-app.jsonl"
    /// The most records that wait for the writer; more are dropped and counted.
    static let queueLimit = 256
    /// A request line longer than this is not kept for its ids.
    static let maxKeptLineBytes = 16 << 10

    /// Monotonic nanoseconds.
    let uptime: @Sendable () -> UInt64

    public convenience init() {
        self.init(uptime: { 0 }, wallMilliseconds: { 0 }, emit: { _ in })
    }

    init(uptime: @escaping @Sendable () -> UInt64, wallMilliseconds: @escaping @Sendable () -> UInt64,
         emit: @escaping @Sendable (String) -> Void) {
        self.uptime = uptime
    }

    /// The folder the file is written in.
    public func setDirectory(_ directory: URL) {}

    /// Records dropped because the queue was full.
    var droppedCount: UInt64 { 0 }

    /// Returns once the writer wrote every record made before the call.
    func flushed() async {}

    func noteRequest(name: String, line: Data?, nanoseconds: UInt64, replyBytes: Int?, timeout: Duration?, failure: (any Error)?) {}

    func noteRollback(name: String, startedAt: UInt64, failure: (any Error)?) {}
}
