/// Counts of main-thread stalls and hangs over one window (default an hour),
/// so short UI hitches that are never sent one by one still reach crash
/// reporting as numbers (``StallSummaryReport``).
///
/// A pure value: the caller holds it under its own lock and passes a
/// monotonic clock in. Nothing runs on a timer: the window closes at the
/// first record after its end (``record(_:nowNanos:)`` then returns the
/// closed window's report) or at quit (``close(nowNanos:)``).
public nonisolated struct StallSummary: Sendable, Equatable {
    /// One thing the watchdog saw.
    public enum Kind: Sendable, Equatable {
        /// A finished stall of this many nanoseconds.
        case stall(nanos: UInt64)
        /// A hang (2 s and still running): sent, or dropped by the hang budget.
        case hang(sent: Bool)
        /// A lag spike sent on its own (``LagSpikeReporter``).
        case spikeSent
    }

    /// The bucket bounds in milliseconds: a stall of `bounds[i]` up to `bounds[i + 1]`.
    public static let bucketBoundsMs: [UInt64] = [50, 100, 250, 500, 1_000, 2_000]
    /// The bucket names, one per bound: the last is open ended.
    public static let bucketNames = ["50-100ms", "100-250ms", "250-500ms", "500ms-1s", "1-2s", "2s+"]

    /// The window length (default one hour).
    public let windowNanos: UInt64
    private var start: UInt64?
    private var counts: [Int]
    private var hangsSent = 0
    private var hangsDropped = 0
    private var spikesSent = 0

    /// - Parameter windowNanos: The window length; at least one second.
    public init(windowNanos: UInt64 = 3_600_000_000_000) {
        self.windowNanos = max(windowNanos, 1_000_000_000)
        counts = Array(repeating: 0, count: Self.bucketNames.count)
    }

    /// Whether the window holds nothing yet.
    public var isEmpty: Bool { counts.allSatisfy { $0 == 0 } && hangsSent == 0 && hangsDropped == 0 && spikesSent == 0 }

    /// Counts `kind` at `nowNanos`.
    /// - Returns: The previous window's report when this record is the first
    ///   after that window ended and it held something; else nil.
    public mutating func record(_ kind: Kind, nowNanos: UInt64) -> StallSummaryReport? {
        var closed: StallSummaryReport?
        if let start, nowNanos >= start &+ windowNanos {
            closed = report(endNanos: nowNanos)
            reset(startNanos: nowNanos)
        } else if start == nil {
            start = nowNanos
        }
        switch kind {
        case let .stall(nanos):
            let ms = nanos / 1_000_000
            if let index = Self.bucketBoundsMs.lastIndex(where: { ms >= $0 }) { counts[index] += 1 }
        case let .hang(sent):
            if sent { hangsSent += 1 } else { hangsDropped += 1 }
        case .spikeSent:
            spikesSent += 1
        }
        return closed
    }

    /// Ends the window now (quit).
    /// - Returns: Its report when it held something; else nil.
    public mutating func close(nowNanos: UInt64) -> StallSummaryReport? {
        let closed = report(endNanos: nowNanos)
        reset(startNanos: nowNanos)
        return closed
    }

    private func report(endNanos: UInt64) -> StallSummaryReport? {
        guard let start, !isEmpty else { return nil }
        let minutes = Int((endNanos &- start) / 60_000_000_000)
        return StallSummaryReport(windowMinutes: max(minutes, 0),
                                  stalls: Dictionary(uniqueKeysWithValues: zip(Self.bucketNames, counts)),
                                  hangsSent: hangsSent, hangsDropped: hangsDropped, spikesSent: spikesSent)
    }

    private mutating func reset(startNanos: UInt64) {
        start = startNanos
        counts = Array(repeating: 0, count: Self.bucketNames.count)
        hangsSent = 0
        hangsDropped = 0
        spikesSent = 0
    }
}
