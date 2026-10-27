public import CmuxNextCompat

/// The `blocking_sites` part of the next report (p12-perf-process-226): what the blocking detector's main-thread
/// sites counted since the last queued report. The detector's counters run from launch (a known site's repeat is
/// one relaxed atomic increment, no stack), so a report sends the difference from the read the last queued report
/// ended at, as ``MainThreadReportLedger`` does for the turn histograms and Chrome's `HistogramSnapshotManager`
/// sends each upload's delta (base/metrics/histogram_snapshot_manager.cc): the server adds reports, so a call is
/// counted once.
///
/// ``take()`` reads without changing anything; ``commit(_:)`` moves the baseline once that report is queued.
/// ``saved()`` keeps what is not yet sent across a quit (``merge(_:)`` at the next launch). A build without the
/// detector reads no site, so its reports carry none.
///
/// ```swift
/// let ledger = BlockingSiteLedger(sites: { detector.mainThreadSites })
/// let taken = ledger.take()
/// let report = builder.build(context: context, watchdog: aggregate, metricKit: inputs, blockingSites: taken.sites)
/// // queue the body, then:
/// ledger.commit(taken)
/// ```
public final class BlockingSiteLedger: Sendable {
    /// One site's counts: cumulative (a read), or since a baseline.
    public struct Entry: Codable, Sendable, Equatable {
        /// ``HangReport/BlockingSiteCount/siteID(location:)`` of the site.
        public var site: String
        /// The `BlockingKind` raw value.
        public var kind: String
        /// Calls that ended at the site.
        public var count: UInt64
        /// Their wall time in nanoseconds.
        public var totalNanos: UInt64

        /// Makes the value from its parts.
        public init(site: String, kind: String, count: UInt64, totalNanos: UInt64) {
            self.site = site
            self.kind = kind
            self.count = count
            self.totalNanos = totalNanos
        }
    }

    /// One ``take()``: what the report carries and what ``commit(_:)`` moves the baseline to.
    public struct Taken: Sendable, Equatable {
        /// The sites of the report, most calls first (at most ``HangReport/maxBlockingSites``).
        public var sites: [HangReport.BlockingSiteCount]
        /// The cumulative read the counts end at; the next baseline.
        var read: [String: Entry]

        /// Whether the report would name no site.
        public var isEmpty: Bool { sites.isEmpty }
    }

    /// What one launch leaves for the next: the counts not yet sent.
    public struct Saved: Codable, Sendable, Equatable {
        /// One entry per site, counts since the last queued report.
        public var entries: [Entry]

        /// Makes the value from its parts.
        public init(entries: [Entry]) {
            self.entries = entries
        }

        /// Whether there is nothing to keep.
        public var isEmpty: Bool { entries.allSatisfy { $0.count == 0 } }
    }

    private struct State {
        /// The cumulative read the last queued report (or the last ``restart()``) ended at.
        var baseline: [String: Entry] = [:]
        /// Counts an earlier launch saved and no report sent yet.
        var carried: [String: Entry] = [:]

        func unsent(_ read: [String: Entry]) -> [String: Entry] {
            var unsent = carried
            for (site, now) in read {
                // A count below its baseline was zeroed since (`debug.blocking reset`): all of it is new.
                let base = baseline[site].flatMap { $0.count <= now.count && $0.totalNanos <= now.totalNanos ? $0 : nil }
                let since = Entry(site: site, kind: now.kind, count: now.count - (base?.count ?? 0),
                                  totalNanos: now.totalNanos - (base?.totalNanos ?? 0))
                guard since.count > 0 else { continue }
                unsent[site] = unsent[site].map { Self.sum($0, since) } ?? since
            }
            return unsent
        }

        static func sum(_ lhs: Entry, _ rhs: Entry) -> Entry {
            let (count, countOverflow) = lhs.count.addingReportingOverflow(rhs.count)
            let (nanos, nanosOverflow) = lhs.totalNanos.addingReportingOverflow(rhs.totalNanos)
            return Entry(site: lhs.site, kind: rhs.kind, count: countOverflow ? .max : count, totalNanos: nanosOverflow ? .max : nanos)
        }
    }

    // Lock carve-out: only the report actor and the quit's one synchronous save touch it, never a hot path; it is
    // never contended, the lock only makes the class Sendable.
    private let state = Mutex(State())
    private let sites: @Sendable () -> [BlockingSite]

    /// - Parameter sites: Reads the detector's main-thread sites (`BlockingDetector.mainThreadSites`; allocates,
    ///   called off the main thread when a report is built, and once at a quit).
    public init(sites: @escaping @Sendable () -> [BlockingSite]) {
        self.sites = sites
    }

    /// The detector's main-thread sites now, by site id.
    private func read() -> [String: Entry] {
        var read: [String: Entry] = [:]
        for site in sites() where site.context == .main {
            let id = HangReport.BlockingSiteCount.siteID(location: site.location)
            let entry = Entry(site: id, kind: site.kind.rawValue, count: UInt64(max(0, site.count)), totalNanos: site.totalNanos)
            read[id] = read[id].map { State.sum($0, entry) } ?? entry
        }
        return read
    }

    /// What the next report would carry; changes nothing.
    public func take() -> Taken {
        let current = read()
        let unsent = state.withLock { $0.unsent(current) }
        return Taken(sites: Self.top(unsent.values), read: current)
    }

    /// The report holding `taken` was queued: its counts leave the ledger.
    public func commit(_ taken: Taken) {
        state.withLock { state in
            state.baseline = taken.read
            state.carried = [:]
        }
    }

    /// Reports were turned on or off: nothing counted before now is sent.
    public func restart() {
        let current = read()
        state.withLock { state in
            state.baseline = current
            state.carried = [:]
        }
    }

    /// What is not yet sent, for the next launch.
    public func saved() -> Saved {
        let current = read()
        let unsent = state.withLock { $0.unsent(current) }
        return Saved(entries: unsent.values.sorted { $0.site < $1.site })
    }

    /// Adds what an earlier launch saved.
    public func merge(_ saved: Saved) {
        state.withLock { state in
            for entry in saved.entries where entry.count > 0 {
                state.carried[entry.site] = state.carried[entry.site].map { State.sum($0, entry) } ?? entry
            }
        }
    }

    /// The sites with the most calls (then the most time, then by id), as a report carries them.
    static func top(_ entries: some Sequence<Entry>) -> [HangReport.BlockingSiteCount] {
        entries.filter { $0.count > 0 }
            .sorted { ($0.count, $0.totalNanos, $1.site) > ($1.count, $1.totalNanos, $0.site) }
            .prefix(HangReport.maxBlockingSites)
            .map { entry in
                HangReport.BlockingSiteCount(site: entry.site, kind: entry.kind, count: Int(clamping: entry.count),
                                             totalMs: Int(clamping: entry.totalNanos / 1_000_000))
            }
    }
}
