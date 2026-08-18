import Darwin

/// A synchronous CPU-time budget shared by regexes in one detection request.
struct CmuxAgentEvaluationDeadline: Sendable {
    /// Keeps a future live reconciliation pass comfortably below one frame
    /// even when a user-authored rule makes ICU backtrack. Thread CPU time is
    /// used so scheduler preemption cannot turn a cheap rule into a false
    /// negative.
    private static let maximumCPUTimeNanoseconds: UInt64 = 10_000_000

    private let clockID: clockid_t?
    private let startingTimeNanoseconds: UInt64

    init() {
        let threadCPUTime = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        if threadCPUTime != 0 {
            self.clockID = CLOCK_THREAD_CPUTIME_ID
            self.startingTimeNanoseconds = threadCPUTime
            return
        }
        let uptime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        self.clockID = uptime == 0 ? nil : CLOCK_UPTIME_RAW
        self.startingTimeNanoseconds = uptime
    }

    var isExceeded: Bool {
        guard let clockID else { return true }
        let current = clock_gettime_nsec_np(clockID)
        guard current != 0, current >= startingTimeNanoseconds else { return true }
        return current - startingTimeNanoseconds
            >= Self.maximumCPUTimeNanoseconds
    }
}
