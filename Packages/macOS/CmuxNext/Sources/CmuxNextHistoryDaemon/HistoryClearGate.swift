import os

private let historyClearLog = Logger(subsystem: "com.cmuxterm.app.next", category: "history")

/// Whether a clear that cannot carry its click as its end may still go. A clear the write queue delivers later must never
/// delete what was made after the click; a daemon without `history-clear-until-v1` (``DaemonHistoryClient/clearUntilCapability``),
/// or an older one with only the direct command delete, clears until its own now. Such a clear goes only when that daemon
/// was connected at the click (`open`, taken then), and only on its first attempt (a retry after a dropped link may land
/// after newer activity), as before the queue; otherwise it is dropped with a log line. A clear that carries its end always goes.
public final class HistoryClearGate {
    private var open: Bool

    /// `open`: the daemon the clear goes to was connected (and served the clear's route) at the click.
    public init(open: Bool) { self.open = open }

    /// Whether the clear may be sent now; `bounded`: it carries the click as its end. An unbounded attempt closes the gate.
    public func allows(bounded: Bool, _ what: String) -> Bool {
        if bounded { return true }
        defer { open = false }
        if !open { historyClearLog.notice("\(what, privacy: .public) dropped: the daemon takes no click-time end and was away at the click or the send was a retry") }
        return open
    }
}
