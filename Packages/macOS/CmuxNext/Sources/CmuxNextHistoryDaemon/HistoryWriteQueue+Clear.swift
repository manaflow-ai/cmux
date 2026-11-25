import os

private let historyClearLog = Logger(subsystem: "com.cmuxterm.app.next", category: "history")

extension HistoryWriteQueue {
    /// Queues a clear made at a click. A clear that cannot carry the click as its end (a daemon without
    /// `history-clear-until-v1`, or an older remote's direct command delete) deletes up to its delivery, so it must never
    /// wait: `live` is that daemon when it is connected at the click; the clear then goes at once on it, only when nothing
    /// is queued, in flight or reading ahead (``sendNow(_:_:done:)``), and once; else it is dropped with a log line. With
    /// `live` nil (the daemon takes the end, or is away and unknown) the clear waits its turn like any write, and `write`
    /// gets `unbounded` false: a daemon that turns out not to take the end drops it then. `done` runs either way.
    public func enqueueClear(live: Client?, _ what: String, _ write: @escaping @Sendable (Client, _ key: String, _ unbounded: Bool) async throws -> Void,
                             done: (@MainActor () -> Void)? = nil) {
        guard let live else { return enqueue({ try await write($0, $1, false) }, done: done) }
        guard sendNow(live, { try await write($0, $1, true) }, done: done) else {
            historyClearLog.notice("\(what, privacy: .public) dropped at the click: the daemon takes no click-time end and writes are ahead of it")
            done?()
            return
        }
    }
}

extension DaemonHistoryClient {
    /// Whether a clear that may not go unbounded (`unbounded` false: it waited in the queue) may go to a daemon that does
    /// (`bounded`) or does not take the click as its end: only one that carries it; the other is dropped with a log line.
    public static func mayClear(bounded: Bool, unbounded: Bool, _ what: String) -> Bool {
        if bounded || unbounded { return true }
        historyClearLog.notice("\(what, privacy: .public) dropped: it waited in the queue and the daemon takes no click-time end")
        return false
    }
}
