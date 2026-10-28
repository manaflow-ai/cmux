#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextCompat
import Foundation

/// `debug.main_jobs.input`'s payload, built from a ``MainJobRing/InputWindow`` off the main thread
/// (sequence-manager-DESIGN.md 2.7, step S6): the main jobs that ran between an input event's arrival and its
/// dispatch, by enqueue site. A measurement, not a pass or fail: its `main_actor` rows are the unposted main jobs
/// (await resumes, `Task` hops, framework jobs) that S5 and the reply form move onto posted tasks.
///
/// - `main_job_input`: the events, how long each waited for its dispatch, and the unposted jobs and time per event
///   (p50 / p95 / p99 / max); the drops of the bounds.
/// - `sites`: one row per enqueuer (``MainJobCensusReport/caller(_:kind:)``, a timer by its owner) and kind, most
///   in-window time first: the job and event counts, the time inside the waits, the jobs' whole run time.
///
/// A job that ran while two events waited counts for each of them.
///
/// ```swift
/// let report = MainJobInputReport(census.inputWindow()) { addresses in symbolicator.frames(for: addresses).map(frame) }
/// ```
public nonisolated struct MainJobInputReport: Sendable, Encodable {
    /// p50, p95, p99 and max of one quantity, with its count.
    public struct Distribution: Sendable, Equatable, Encodable {
        public var n: Int
        public var p50: Double
        public var p95: Double
        public var p99: Double
        public var max: Double

        /// Nearest-rank percentiles of `values` (all zero when empty).
        init(_ values: [Double]) {
            let sorted = values.sorted()
            func rank(_ p: Double) -> Double {
                guard !sorted.isEmpty else { return 0 }
                return sorted[Swift.min(sorted.count - 1, Swift.max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))]
            }
            n = sorted.count
            p50 = rank(0.5)
            p95 = rank(0.95)
            p99 = rank(0.99)
            max = sorted.last ?? 0
        }
    }

    public struct Summary: Sendable, Equatable, Encodable {
        public var armed = true
        public var events: Int
        /// Events whose wait held at least one job.
        public var eventsWithJobs: Int
        /// Job and event pairs (a job counts once per event it delayed).
        public var jobs: Int
        /// The pairs whose job is an unposted main-actor job.
        public var unpostedJobs: Int
        /// Arrival to dispatch, milliseconds.
        public var waitMs: Distribution
        /// Unposted main-actor jobs per event.
        public var unpostedPerEvent: Distribution
        /// Unposted main-actor jobs' time inside each event's wait, milliseconds.
        public var unpostedMsPerEvent: Distribution
        public var droppedEvents: Int
        public var droppedJobs: Int
        public var busyDrops: Int

        private enum CodingKeys: String, CodingKey {
            case armed, events, jobs
            case eventsWithJobs = "events_with_jobs", unpostedJobs = "unposted_jobs", waitMs = "wait_ms"
            case unpostedPerEvent = "unposted_per_event", unpostedMsPerEvent = "unposted_ms_per_event"
            case droppedEvents = "dropped_events", droppedJobs = "dropped_jobs", busyDrops = "busy_drops"
        }
    }

    public struct Site: Sendable, Equatable, Encodable {
        public var caller: String
        /// ``MainJobCensusReport/kindName(_:)``: `main_actor` is unposted.
        public var kind: String
        public var jobs: Int
        public var events: Int
        public var inWindowMs: Double
        public var runMs: Double
        public var maxRunMs: Double

        private enum CodingKeys: String, CodingKey {
            case caller, kind, jobs, events
            case inWindowMs = "in_window_ms", runMs = "run_ms", maxRunMs = "max_run_ms"
        }
    }

    public var summary: Summary
    public var sites: [Site]

    private enum CodingKeys: String, CodingKey {
        case summary = "main_job_input", sites
    }

    /// - Parameters:
    ///   - window: The ring's input window.
    ///   - siteLimit: The most site rows kept (most in-window time first).
    ///   - symbolize: Resolves one job's return addresses, innermost first; called once per distinct stack.
    public init(_ window: MainJobRing.InputWindow, siteLimit: Int = 60, symbolize: ([UInt]) -> [MainJobCensusReport.Frame]) {
        func ms(_ nanos: UInt64) -> Double { (Double(nanos) / 1_000).rounded() / 1_000 }
        var resolved: [[UInt]: String] = [:]
        var rows: [String: (site: Site, events: Set<Int>)] = [:]
        var unposted = Array(repeating: (jobs: 0, nanos: UInt64(0)), count: window.events.count)
        var withJobs = Set<Int>()
        for entry in window.jobs {
            let job = entry.job
            let caller: String
            if let label = job.label {
                caller = "timer \(label)"
            } else if let known = resolved[job.frames] {
                caller = known
            } else {
                caller = MainJobCensusReport.caller(symbolize(job.frames), kind: job.kind)
                resolved[job.frames] = caller
            }
            let kind = MainJobCensusReport.kindName(job.kind)
            let key = kind + "\u{0}" + caller
            var row = rows[key] ?? (Site(caller: caller, kind: kind, jobs: 0, events: 0, inWindowMs: 0, runMs: 0, maxRunMs: 0), [])
            row.site.jobs += 1
            row.site.inWindowMs += ms(entry.inWindowNanos)
            row.site.runMs += ms(job.runNanos)
            row.site.maxRunMs = Swift.max(row.site.maxRunMs, ms(job.runNanos))
            row.events.insert(entry.event)
            rows[key] = row
            withJobs.insert(entry.event)
            if job.kind == .mainActor, unposted.indices.contains(entry.event) {
                unposted[entry.event].jobs += 1
                unposted[entry.event].nanos &+= entry.inWindowNanos
            }
        }
        sites = rows.values.map { row in
            var site = row.site
            site.events = row.events.count
            site.inWindowMs = (site.inWindowMs * 1_000).rounded() / 1_000
            site.runMs = (site.runMs * 1_000).rounded() / 1_000
            return site
        }
        .sorted { ($0.inWindowMs, $0.jobs, $0.caller) > ($1.inWindowMs, $1.jobs, $1.caller) }
        .prefix(siteLimit).map { $0 }
        let waits = window.events.map { ms($0.dispatchNanos > $0.arrivalNanos ? $0.dispatchNanos - $0.arrivalNanos : 0) }
        summary = Summary(events: window.events.count, eventsWithJobs: withJobs.count, jobs: window.jobs.count,
                          unpostedJobs: unposted.reduce(0) { $0 + $1.jobs }, waitMs: Distribution(waits),
                          unpostedPerEvent: Distribution(unposted.map { Double($0.jobs) }),
                          unpostedMsPerEvent: Distribution(unposted.map { ms($0.nanos) }),
                          droppedEvents: window.droppedEvents, droppedJobs: window.droppedJobs, busyDrops: window.busyDrops)
    }

    /// The report as a `JSONSerialization` object graph, the control reply's form.
    public func foundationObject() throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(self))
    }
}
#endif
