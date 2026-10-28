/// The slow-launch trace (``HangReport/launchTrace``, p08-startup-111), by allow-list: closed-set kinds, temperatures and
/// reasons, bounded numbers, and code-identifier names that hold no personal term.
extension HangReportBuilder {
    /// Whether this builder's reports carry ``HangReport/launchTrace``: schema 3, and told to send it.
    public var carriesLaunchTrace: Bool { sendsLaunchTrace && wireSchema.carriesLaunchTrace }

    /// The longest time a launch trace names (one day, in microseconds); a larger one is sent as this.
    static let maxLaunchTraceMicros: UInt64 = HangReport.LaunchTrace.maxMicros

    /// `trace` rebuilt for the wire, so a pending file edited on disk sends nothing else: its numbers in range, its
    /// budget this build's for its temperature, and at most ``HangReport/maxLaunchTraceEvents`` events, the cut ones
    /// counted in `dropped` (``HangReport/LaunchTrace/bounded``); nil when its first frame did not miss that budget.
    /// Each name that is not a code identifier, or that holds a personal term, becomes ``HangReport/LaunchTrace/other``.
    func safeLaunchTrace(_ trace: HangReport.LaunchTrace) -> HangReport.LaunchTrace? {
        var safe = trace.bounded
        guard safe.firstFrameMs > safe.budgetMs else { return nil }
        safe.events = safe.events.map { event in
            HangReport.LaunchTrace.Event(startMicros: event.startMicros, durationMicros: event.durationMicros, kind: event.kind,
                                         name: launchTraceName(event.name))
        }
        return safe
    }

    /// `name` when it is a code identifier of at most 64 letters, digits, `.`, `_` and `-` that the classifier would
    /// send (no personal term), else ``HangReport/LaunchTrace/other``.
    func launchTraceName(_ name: String) -> String {
        let identifier = name.range(of: #"^[A-Za-z][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil
        return identifier && classifier.sendableName(name) != nil ? name : HangReport.LaunchTrace.other
    }
}
