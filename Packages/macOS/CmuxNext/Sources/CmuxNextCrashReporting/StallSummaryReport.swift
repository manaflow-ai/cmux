public import Sentry

/// One closed window of ``StallSummary``: how many main-thread stalls of each
/// length the app had, and how many hangs and lag spikes it sent or dropped.
///
/// Sent as one info event per window, all in one Sentry issue (fingerprint
/// `main_thread_stall_summary`), with each count both as a number (`extra`)
/// and as a searchable tag, so the team can filter by build, install or
/// reporter and read the counts per Mac.
public nonisolated struct StallSummaryReport: Sendable, Equatable {
    /// The window's length in whole minutes.
    public let windowMinutes: Int
    /// Finished stalls per bucket (``StallSummary/bucketNames``).
    public let stalls: [String: Int]
    /// Hangs sent with their stack.
    public let hangsSent: Int
    /// Hangs the hang budget dropped (a flood): counted here only.
    public let hangsDropped: Int
    /// Lag spikes sent with their stack.
    public let spikesSent: Int

    /// - Parameters:
    ///   - windowMinutes: The window's length in minutes.
    ///   - stalls: Finished stalls per bucket name.
    ///   - hangsSent: Hangs sent.
    ///   - hangsDropped: Hangs dropped by the budget.
    ///   - spikesSent: Lag spikes sent.
    public init(windowMinutes: Int, stalls: [String: Int], hangsSent: Int, hangsDropped: Int, spikesSent: Int) {
        self.windowMinutes = windowMinutes
        self.stalls = stalls
        self.hangsSent = hangsSent
        self.hangsDropped = hangsDropped
        self.spikesSent = spikesSent
    }

    /// Every finished stall of 50 ms and up in the window.
    public var totalStalls: Int { stalls.values.reduce(0, +) }

    /// The Sentry event: info level, one issue for every summary.
    public func event() -> Event {
        let event = Event(level: .info)
        event.platform = "cocoa"
        event.message = SentryMessage(formatted: "main thread stall summary")
        event.fingerprint = ["main_thread_stall_summary"]
        var tags = ["hang_source": "stall_summary", "summary_window_min": String(windowMinutes),
                    "stalls_total": String(totalStalls), "hangs_total": String(hangsSent + hangsDropped)]
        var extra: [String: Any] = ["window_minutes": windowMinutes, "stalls_total": totalStalls,
                                    "hangs_sent": hangsSent, "hangs_dropped": hangsDropped, "spikes_sent": spikesSent]
        for name in StallSummary.bucketNames {
            let count = stalls[name] ?? 0
            tags["stalls_\(name)"] = String(count)
            extra["stalls_\(name)"] = count
        }
        event.tags = tags
        event.extra = extra
        return event
    }
}
