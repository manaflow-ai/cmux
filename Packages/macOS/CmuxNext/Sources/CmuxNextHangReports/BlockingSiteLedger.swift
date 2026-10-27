public import CmuxNextCompat

/// The `blocking_sites` part of the next report (p12-perf-process-226): what the blocking detector's main-thread
/// sites counted since the last queued report. The detector's counters run from launch (a known site's repeat is
/// one relaxed atomic increment, no stack), so a report sends the difference from the read the last queued report
/// ended at, as ``MainThreadReportLedger`` does for the turn histograms and Chrome's `HistogramSnapshotManager`
/// sends each upload's delta (base/metrics/histogram_snapshot_manager.cc): the server adds reports, so a call is
/// counted once.
///
/// ``take()`` reads without changing anything; ``commit(_:)`` moves the baseline of the sites that report sent once
/// it is queued, so a site past the report's top ``HangReport/maxBlockingSites`` stays pending for a later one.
/// A `debug.blocking reset` zeroes the counters and adds one to the read's reset count, which puts every baseline
/// back at zero. ``saved()`` keeps what is not yet sent across a quit (``merge(_:)`` at the next launch). A build
/// without the detector reads no site, so its reports carry none.
///
/// ```swift
/// let ledger = BlockingSiteLedger(sites: { detector.mainThreadRead })
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
        /// The cumulative read the counts end at: the next baseline of each sent site.
        var read: [String: Entry]
        /// The detector's reset count that read follows.
        var resets: Int

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

    /// One read of the detector: its main-thread sites by site id, and the reset count they follow.
    private struct Read {
        var entries: [String: Entry]
        var resets: Int
    }

    private struct State {
        /// Per site, the cumulative read the last report that sent it (or the last ``restart()``) ended at.
        var baseline: [String: Entry] = [:]
        /// The detector's reset count the baselines belong to; another one means the counters were zeroed since.
        var resets = 0
        /// Counts an earlier launch saved and no report sent yet.
        var carried: [String: Entry] = [:]

        func unsent(_ read: Read) -> [String: Entry] {
            var unsent = carried
            let bases = read.resets == resets ? baseline : [:]
            for (site, now) in read.entries {
                let base = bases[site]
                let since = Entry(site: site, kind: now.kind, count: Self.difference(now.count, base?.count),
                                  totalNanos: Self.difference(now.totalNanos, base?.totalNanos))
                guard since.count > 0 else { continue }
                unsent[site] = unsent[site].map { Self.sum($0, since) } ?? since
            }
            return unsent
        }

        mutating func commit(_ taken: Taken) {
            if taken.resets != resets {
                baseline = [:]
                resets = taken.resets
            }
            for sent in taken.sites {
                baseline[sent.site] = taken.read[sent.site]
                carried[sent.site] = nil
            }
        }

        /// `now` less `base`: a read taken while a reset was zeroing can be below its baseline, and counts 0.
        static func difference(_ now: UInt64, _ base: UInt64?) -> UInt64 {
            guard let base else { return now }
            return now > base ? now - base : 0
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
    private let sites: @Sendable () -> BlockingDetector.MainThreadRead

    /// - Parameter sites: Reads the detector's main-thread sites and reset count (`BlockingDetector.mainThreadRead`;
    ///   allocates, called off the main thread when a report is built, and once at a quit).
    public init(sites: @escaping @Sendable () -> BlockingDetector.MainThreadRead) {
        self.sites = sites
    }

    /// The detector's main-thread sites now, by site id.
    private func read() -> Read {
        let detector = sites()
        var entries: [String: Entry] = [:]
        for site in detector.sites where site.context == .main {
            let id = HangReport.BlockingSiteCount.siteID(location: site.location)
            let entry = Entry(site: id, kind: site.kind.rawValue, count: UInt64(max(0, site.count)), totalNanos: site.totalNanos)
            entries[id] = entries[id].map { State.sum($0, entry) } ?? entry
        }
        return Read(entries: entries, resets: detector.resets)
    }

    /// What the next report would carry; changes nothing.
    public func take() -> Taken {
        let current = read()
        let unsent = state.withLock { $0.unsent(current) }
        return Taken(sites: Self.top(unsent.values), read: current.entries, resets: current.resets)
    }

    /// The report holding `taken` was queued: the counts of the sites it sent leave the ledger; the others wait.
    public func commit(_ taken: Taken) {
        state.withLock { $0.commit(taken) }
    }

    /// Reports were turned on or off: nothing counted before now is sent.
    public func restart() {
        let current = read()
        state.withLock { state in
            state.baseline = current.entries
            state.resets = current.resets
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
