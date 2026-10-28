/// The slow-launch trace (``HangReport/launchTrace``, p08-startup-111), by allow-list: closed-set kinds, temperatures and
/// reasons, bounded numbers, and code-identifier names that hold no personal term.
extension HangReportBuilder {
    /// Whether this builder's reports carry ``HangReport/launchTrace``: schema 3, and told to send it.
    public var carriesLaunchTrace: Bool { sendsLaunchTrace && wireSchema.carriesLaunchTrace }

    /// The longest time a launch trace names (one day, in microseconds); a larger one is sent as this.
    static let maxLaunchTraceMicros: UInt64 = UInt64(HistogramBucket.maxMs) * 1_000

    /// `trace` rebuilt for the wire, so a pending file edited on disk sends nothing else: its budget is this build's
    /// for its temperature, and nil when its first frame did not miss that budget. Each name that is not a code
    /// identifier, or that holds a personal term, becomes ``HangReport/LaunchTrace/other``; the events are cut to
    /// ``HangReport/maxLaunchTraceEvents`` (``launchTraceEvents(_:)``), and what was cut is counted in `dropped`.
    func safeLaunchTrace(_ trace: HangReport.LaunchTrace) -> HangReport.LaunchTrace? {
        let budget = HangReport.LaunchTrace.firstFrameBudgetMs(trace.temperature)
        let firstFrame = Self.clampedMs(trace.firstFrameMs)
        guard firstFrame > budget else { return nil }
        let events = Self.launchTraceEvents(trace.events).map { event in
            HangReport.LaunchTrace.Event(startMicros: min(event.startMicros, Self.maxLaunchTraceMicros),
                                         durationMicros: event.kind == .mark ? 0 : min(event.durationMicros, Self.maxLaunchTraceMicros),
                                         kind: event.kind, name: launchTraceName(event.name))
        }
        let cut = trace.events.count - events.count
        return HangReport.LaunchTrace(temperature: trace.temperature, reason: trace.reason, firstFrameMs: firstFrame, budgetMs: budget,
                                      startupCompleteMs: Self.clampedMs(trace.startupCompleteMs),
                                      dropped: min(max(0, trace.dropped).saturatingAdding(cut), LaunchHistogram.maxCount), events: events)
    }

    /// `name` when it is a code identifier of at most 64 letters, digits, `.`, `_` and `-` that the classifier would
    /// send (no personal term), else ``HangReport/LaunchTrace/other``.
    func launchTraceName(_ name: String) -> String {
        let identifier = name.range(of: #"^[A-Za-z][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil
        return identifier && classifier.sendableName(name) != nil ? name : HangReport.LaunchTrace.other
    }

    /// At most ``HangReport/maxLaunchTraceEvents`` of `events`, by start time: every mark (the launch's milestones,
    /// the oldest first when there are more), then the longest slices in the room left.
    static func launchTraceEvents(_ events: [HangReport.LaunchTrace.Event]) -> [HangReport.LaunchTrace.Event] {
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
    static func clampedMs(_ ms: Int) -> Int {
        min(max(0, ms), HistogramBucket.maxMs)
    }
}
