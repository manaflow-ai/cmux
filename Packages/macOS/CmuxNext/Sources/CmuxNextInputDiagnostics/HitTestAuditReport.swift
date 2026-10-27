public import Foundation

/// `debug.input hittest`: schema ``currentSchema``, keys sorted, integers only, rows in a fixed order, so the same
/// samples give the same bytes. Times are nanoseconds.
public nonisolated struct HitTestAuditReport: Sendable, Equatable, Codable {
    public static let currentSchema = "cmux.hittest.v1"
    /// ``Row/costly`` reasons.
    public static let p99NanosReason = "p99_ns"
    public static let p99ViewsReason = "p99_views"

    /// Nearest-rank percentiles of the kept samples; all 0 with none.
    public nonisolated struct Distribution: Sendable, Equatable, Codable {
        public var p50: UInt64
        public var p95: UInt64
        public var p99: UInt64
        public var max: UInt64

        init(_ samples: [UInt64]) {
            let sorted = samples.sorted()
            func rank(_ fraction: Double) -> UInt64 {
                guard !sorted.isEmpty else { return 0 }
                let index = Int((Double(sorted.count) * fraction).rounded(.up)) - 1
                return sorted[Swift.min(Swift.max(index, 0), sorted.count - 1)]
            }
            p50 = rank(0.50)
            p95 = rank(0.95)
            p99 = rank(0.99)
            max = sorted.last ?? 0
        }
    }

    /// Every outermost hit test.
    public nonisolated struct Summary: Sendable, Equatable, Codable {
        /// Since the install or the last reset.
        public var count: UInt64
        /// The most recent ones the percentiles read.
        public var sampled: Int
        public var ns: Distribution
        public var views: Distribution
    }

    /// Every input event that ran at least one hit test: the sums over its hit tests.
    public nonisolated struct EventSummary: Sendable, Equatable, Codable {
        public var count: UInt64
        public var sampled: Int
        public var ns: Distribution
        public var views: Distribution
        public var hitTests: Distribution

        private enum CodingKeys: String, CodingKey {
            case count, sampled, ns, views
            case hitTests = "hit_tests"
        }
    }

    /// One `hitTest:` implementation.
    public nonisolated struct Row: Sendable, Equatable, Codable {
        /// The class that defines it, or the class of the views that inherit NSView's own.
        public var className: String
        /// The class defines `hitTest:` itself.
        public var definesHitTest: Bool
        public var calls: UInt64
        public var sampled: Int
        /// Per call.
        public var ns: Distribution
        public var views: Distribution
        /// Per event that ran it: the sums over its calls in the event (a call inside another of the same row
        /// counts in that one only), and how many calls they are.
        public var perEvent: EventSummary
        /// Why it is costly (``HitTestAuditReport/p99NanosReason``, ``HitTestAuditReport/p99ViewsReason``): a p99,
        /// per call or per event, over its threshold. Empty when it is not.
        public var costly: [String]

        private enum CodingKeys: String, CodingKey {
            case className = "class"
            case definesHitTest = "override"
            case perEvent = "per_event"
            case calls, sampled, ns, views, costly
        }
    }

    public var schema: String
    /// The build has the hooks.
    public var available: Bool
    public var installed: Bool
    public var hookedImplementations: Int
    public var thresholds: HitTestAuditThresholds
    public var events: EventSummary
    public var hitTests: Summary
    /// Rows with calls: highest p99 time first, then most p99 views, then by class name, overrides first.
    public var rows: [Row]
    /// The costly overrides' class names, in row order (one MQ-hittest task each: a region cache or an early return).
    /// A row of a class that inherits NSView's `hitTest:` stays out: it has no override to fix.
    public var costly: [String]

    private enum CodingKeys: String, CodingKey {
        case schema, available, installed, thresholds, events, rows, costly
        case hookedImplementations = "hooked_implementations"
        case hitTests = "hit_tests"
    }

    /// The report of `snapshot`, its percentiles computed off the main thread.
    @concurrent
    static func making(from snapshot: HitTestAuditSnapshot, thresholds: HitTestAuditThresholds) async -> Self {
        Self(snapshot: snapshot, thresholds: thresholds)
    }

    init(snapshot: HitTestAuditSnapshot, thresholds: HitTestAuditThresholds) {
        schema = Self.currentSchema
        available = snapshot.available
        installed = snapshot.installed
        hookedImplementations = snapshot.hookedImplementations
        self.thresholds = thresholds
        events = EventSummary(
            count: snapshot.events.calls,
            sampled: snapshot.events.nanos.count,
            ns: Distribution(snapshot.events.nanos),
            views: Distribution(snapshot.events.views),
            hitTests: Distribution(snapshot.events.hitTests)
        )
        hitTests = Summary(
            count: snapshot.hitTests.calls,
            sampled: snapshot.hitTests.nanos.count,
            ns: Distribution(snapshot.hitTests.nanos),
            views: Distribution(snapshot.hitTests.views)
        )
        rows = Self.merged(snapshot.rows).map { Self.row($0, thresholds: thresholds) }.sorted { lhs, rhs in
            if lhs.ns.p99 != rhs.ns.p99 { return lhs.ns.p99 > rhs.ns.p99 }
            if lhs.views.p99 != rhs.views.p99 { return lhs.views.p99 > rhs.views.p99 }
            if lhs.className != rhs.className { return lhs.className < rhs.className }
            return lhs.definesHitTest && !rhs.definesHitTest
        }
        costly = rows.filter { $0.definesHitTest && !$0.costly.isEmpty }.map(\.className)
    }

    /// Rows with calls, those of one name and kind (a class and its KVO subclass) as one.
    private static func merged(_ rows: [HitTestAuditSnapshot.RowSamples]) -> [HitTestAuditSnapshot.RowSamples] {
        var order: [String] = []
        var byKey: [String: HitTestAuditSnapshot.RowSamples] = [:]
        for row in rows where row.samples.calls > 0 {
            let key = "\(row.definesHitTest ? 1 : 0)\(row.name)"
            guard var existing = byKey[key] else {
                order.append(key)
                byKey[key] = row
                continue
            }
            existing.samples.calls &+= row.samples.calls
            existing.samples.nanos += row.samples.nanos
            existing.samples.views += row.samples.views
            existing.samples.hitTests += row.samples.hitTests
            existing.eventSamples.calls &+= row.eventSamples.calls
            existing.eventSamples.nanos += row.eventSamples.nanos
            existing.eventSamples.views += row.eventSamples.views
            existing.eventSamples.hitTests += row.eventSamples.hitTests
            byKey[key] = existing
        }
        return order.compactMap { byKey[$0] }
    }

    private static func row(_ row: HitTestAuditSnapshot.RowSamples, thresholds: HitTestAuditThresholds) -> Row {
        let ns = Distribution(row.samples.nanos)
        let views = Distribution(row.samples.views)
        let perEvent = EventSummary(
            count: row.eventSamples.calls,
            sampled: row.eventSamples.nanos.count,
            ns: Distribution(row.eventSamples.nanos),
            views: Distribution(row.eventSamples.views),
            hitTests: Distribution(row.eventSamples.hitTests)
        )
        var reasons: [String] = []
        if Swift.max(ns.p99, perEvent.ns.p99) > thresholds.p99NanosOver { reasons.append(p99NanosReason) }
        if Swift.max(views.p99, perEvent.views.p99) > thresholds.p99ViewsOver { reasons.append(p99ViewsReason) }
        return Row(
            className: row.name,
            definesHitTest: row.definesHitTest,
            calls: row.samples.calls,
            sampled: row.samples.nanos.count,
            ns: ns,
            views: views,
            perEvent: perEvent,
            costly: reasons
        )
    }

    /// The JSON: keys sorted, so the same report gives the same bytes.
    public func jsonData() throws(HitTestAuditError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(self)
        } catch {
            throw HitTestAuditError.encoding(String(describing: error))
        }
    }
}

/// Why a ``HitTestAuditReport`` could not be written.
public nonisolated enum HitTestAuditError: Error, Equatable {
    case encoding(String)
}

/// The recorded samples, copied once on the main thread for ``HitTestAuditReport``.
nonisolated struct HitTestAuditSnapshot: Sendable {
    nonisolated struct Samples: Sendable {
        /// Calls since the install or the last reset.
        var calls: UInt64
        /// The kept samples (the most recent ones), one column per measure, in no order across columns' rows.
        var nanos: [UInt64]
        var views: [UInt64]
        var hitTests: [UInt64]
    }

    nonisolated struct RowSamples: Sendable {
        var name: String
        var definesHitTest: Bool
        var samples: Samples
        /// Per event, the row's sums (``HitTestAuditReport/Row/perEvent``).
        var eventSamples: Samples
    }

    var available: Bool
    var installed: Bool
    var hookedImplementations: Int
    var events: Samples
    var hitTests: Samples
    var rows: [RowSamples]
}
