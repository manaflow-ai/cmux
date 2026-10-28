/// Schema 3's slow-launch trace (`launch_trace`, plans/cmux-next/chrome-parity/p08-startup.md task 111): the names and
/// times of one launch whose first frame came after its p95 budget, from the 32 KiB ring the app kept until
/// `startup_complete` (CmuxNextLaunch's `StartupTrace.SlowLaunchRing`).
///
/// Chrome's background tracing (content/browser/tracing/background_tracing_manager_impl.cc): a field client keeps a
/// small ring while a scenario runs and uploads it only when the scenario's trigger fires; otherwise the ring is
/// thrown away. Here the scenario is the launch and the trigger is a first frame past the launch's p95 budget
/// (``exceedsBudget(_:)``). The ring holds names only (code-defined mark, task and lane names) and times; no argument,
/// path or title is ever in it.
///
/// ```swift
/// if let trace = HangReport.LaunchTrace(launch: record, events: events, dropped: taken.overwritten) {
///     collector.noteLaunchTrace(trace)
/// }
/// ```
extension HangReport {
    /// The most events one launch trace carries: every mark, then the longest slices (``HangReportBuilder``).
    public static let maxLaunchTraceEvents = 128

    /// One slow launch: its milestones, the budget it missed, and the trace events of its ring.
    public struct LaunchTrace: Codable, Sendable, Equatable {
        /// What an event was, a closed set.
        public enum Kind: String, Codable, Sendable, CaseIterable {
            /// A launch mark (an instant).
            case mark
            /// A startup task that ran on the main thread.
            case mainTask = "main_task"
            /// A startup task that ran on a lane.
            case laneTask = "lane_task"
            /// A main run-loop turn over 1 ms.
            case mainTurn = "main_turn"
            /// A background lane job over 1 ms.
            case laneJob = "lane_job"
        }

        /// One event, on the wire as `[t_us, dur_us, kind, name]`.
        public struct Event: Codable, Sendable, Equatable {
            /// Microseconds after process start.
            public var startMicros: UInt64
            /// Microseconds it ran; 0 for a mark.
            public var durationMicros: UInt64
            /// What it was.
            public var kind: Kind
            /// Its code-defined name (``HangReport/LaunchTrace/other`` when it was not one).
            public var name: String

            /// Makes the value from its parts.
            public init(startMicros: UInt64, durationMicros: UInt64, kind: Kind, name: String) {
                self.startMicros = startMicros
                self.durationMicros = durationMicros
                self.kind = kind
                self.name = name
            }

            public init(from decoder: any Decoder) throws {
                var tuple = try decoder.unkeyedContainer()
                startMicros = try tuple.decode(UInt64.self)
                durationMicros = try tuple.decode(UInt64.self)
                kind = try tuple.decode(Kind.self)
                name = try tuple.decode(String.self)
                guard tuple.isAtEnd else {
                    throw DecodingError.dataCorruptedError(in: tuple, debugDescription: "an event is [t_us, dur_us, kind, name]")
                }
            }

            public func encode(to encoder: any Encoder) throws {
                var tuple = encoder.unkeyedContainer()
                try tuple.encode(startMicros)
                try tuple.encode(durationMicros)
                try tuple.encode(kind)
                try tuple.encode(name)
            }
        }

        /// The name an event gets when its own is not a sendable code identifier.
        public static let other = "other"

        /// The launch's temperature.
        public var temperature: LaunchTemperature
        /// Why startup completed.
        public var reason: LaunchCompletionReason
        /// Process start to the first committed window frame.
        public var firstFrameMs: Int
        /// The p95 first-frame budget of its temperature (``firstFrameBudgetMs(_:)``).
        public var budgetMs: Int
        /// Process start to `startup_complete`.
        public var startupCompleteMs: Int
        /// Events the ring overwrote or the report cut.
        public var dropped: Int
        /// The events, oldest first.
        public var events: [Event]

        /// Makes the value from its parts.
        public init(temperature: LaunchTemperature, reason: LaunchCompletionReason, firstFrameMs: Int, budgetMs: Int,
                    startupCompleteMs: Int, dropped: Int, events: [Event]) {
            self.temperature = temperature
            self.reason = reason
            self.firstFrameMs = firstFrameMs
            self.budgetMs = budgetMs
            self.startupCompleteMs = startupCompleteMs
            self.dropped = dropped
            self.events = events
        }

        /// The trace of `launch` when it exceeded its budget (``exceedsBudget(_:)``), else nil: the caller frees
        /// the ring and nothing is kept.
        public init?(launch: LaunchAggregate.Record, events: [Event], dropped: Int) {
            guard Self.exceedsBudget(launch), let firstFrame = launch.firstFrame else { return nil }
            self.init(temperature: launch.temperature, reason: launch.reason,
                      firstFrameMs: LaunchAggregate.milliseconds(firstFrame), budgetMs: Self.firstFrameBudgetMs(launch.temperature),
                      startupCompleteMs: LaunchAggregate.milliseconds(launch.startupComplete), dropped: max(0, dropped), events: events)
        }

        /// The p95 first-frame budget of a launch at `temperature`, in milliseconds: the startup program's done checks
        /// (p08-startup.md section 5: warm p95 <= 180 ms, cold p95 <= 360 ms). A lukewarm or undetermined launch is
        /// judged by the cold budget, so only a launch that misses the looser bound is traced.
        public static func firstFrameBudgetMs(_ temperature: LaunchTemperature) -> Int {
            switch temperature {
            case .warm: 180
            case .lukewarm, .cold, .undetermined: 360
            }
        }

        /// Whether `launch`'s first frame came after its budget. An interrupted launch (something other than cmux
        /// slowed it, task p08-startup-108) and a launch that showed no window are never traced.
        public static func exceedsBudget(_ launch: LaunchAggregate.Record) -> Bool {
            guard !launch.interrupted, let firstFrame = launch.firstFrame else { return false }
            return LaunchAggregate.milliseconds(firstFrame) > firstFrameBudgetMs(launch.temperature)
        }

        /// How far past its budget the first frame came: of two slow launches, a report keeps the one further past.
        /// From the clamped first frame and this build's budget, so a saved trace's numbers cannot overflow it.
        public var overrunMs: Int { Self.clampedMs(firstFrameMs) - Self.firstFrameBudgetMs(temperature) }

        /// The longest time an event names (one day, in microseconds); a larger one is this.
        public static let maxMicros: UInt64 = UInt64(HistogramBucket.maxMs) * 1_000

        /// This trace with every number in range, as the pending aggregate keeps it (a saved file is untrusted):
        /// milliseconds in `0...HistogramBucket.maxMs`, this build's budget for its temperature, `dropped` in
        /// `0...LaunchHistogram.maxCount`, event times at most ``maxMicros`` (a mark lasts 0), and at most
        /// ``HangReport/maxLaunchTraceEvents`` events (``kept(_:)``), the cut ones counted in `dropped`.
        public var bounded: LaunchTrace {
            let kept = Self.kept(events).map { event in
                Event(startMicros: min(event.startMicros, Self.maxMicros),
                      durationMicros: event.kind == .mark ? 0 : min(event.durationMicros, Self.maxMicros), kind: event.kind, name: event.name)
            }
            return LaunchTrace(temperature: temperature, reason: reason, firstFrameMs: Self.clampedMs(firstFrameMs),
                               budgetMs: Self.firstFrameBudgetMs(temperature), startupCompleteMs: Self.clampedMs(startupCompleteMs),
                               dropped: min(max(0, dropped).saturatingAdding(events.count - kept.count), LaunchHistogram.maxCount),
                               events: kept)
        }

        /// At most ``HangReport/maxLaunchTraceEvents`` of `events`, by start time: every mark (the launch's milestones,
        /// the oldest first when there are more), then the longest slices in the room left.
        public static func kept(_ events: [Event]) -> [Event] {
            let cap = HangReport.maxLaunchTraceEvents
            let indexed = Array(events.enumerated())
            var kept = indexed
            if indexed.count > cap {
                let marks = indexed.filter { $0.element.kind == .mark }.prefix(cap)
                let slices = indexed.filter { $0.element.kind != .mark }
                    .sorted { ($0.element.durationMicros, $1.offset) > ($1.element.durationMicros, $0.offset) }
                    .prefix(cap - marks.count)
                kept = Array(marks) + Array(slices)
            }
            return kept.sorted { ($0.element.startMicros, $0.offset) < ($1.element.startMicros, $1.offset) }.map(\.element)
        }

        /// Whole milliseconds clamped to `0...HistogramBucket.maxMs`.
        public static func clampedMs(_ ms: Int) -> Int {
            min(max(0, ms), HistogramBucket.maxMs)
        }

        private enum CodingKeys: String, CodingKey {
            case temperature, reason, dropped, events
            case firstFrameMs = "first_frame_ms"
            case budgetMs = "budget_ms"
            case startupCompleteMs = "startup_complete_ms"
        }
    }
}
