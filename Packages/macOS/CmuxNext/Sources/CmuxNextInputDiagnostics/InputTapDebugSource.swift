public import CmuxNextControl
public import CmuxNextInput
public import CmuxNextInputCore

/// `debug.input` section `tap` from the app's one input tap: one main-actor copy of its subscription
/// counts and flags per read, nothing per event.
public nonisolated struct InputTapDebugSource: DebugInputSource {
    private let tap: InputEventTap

    /// - Parameter tap: The app's one input tap.
    public init(tap: InputEventTap) {
        self.tap = tap
    }

    public var section: DebugInputSection { .tap }

    public func read() async -> DebugInputTap {
        await MainActor.run { [tap] in Self.snapshot(tap) }
    }

    /// The tap keeps no counters: nothing to start over.
    public func reset() async {}

    @MainActor
    static func snapshot(_ tap: InputEventTap) -> DebugInputTap {
        var flags: [String] = []
        if tap.flags.contains(.hintsShowing) { flags.append("hints_showing") }
        if tap.flags.contains(.findPillOpen) { flags.append("find_pill_open") }
        return DebugInputTap(
            subscribers: InputEventClass.allCases.map { eventClass in
                DebugInputTap.Subscribers(eventClass: String(describing: eventClass),
                                          observe: tap.subscriberCount(eventClass, stage: .observe),
                                          intercept: tap.subscriberCount(eventClass, stage: .intercept),
                                          afterDispatch: tap.subscriberCount(eventClass, stage: .afterDispatch))
            },
            globalMonitors: tap.globalMonitorCount,
            flags: flags,
            lastDispatched: tap.lastDispatched.map { String(describing: $0.type) })
    }
}

/// `debug.input` section `latency`: the input latency ledger (p04-input-002), folded up to the read.
nonisolated extension InputLatencyReporter: DebugInputSource {
    public var section: DebugInputSection { .latency }

    public func read() async -> InputLatencySnapshot {
        await snapshot()
    }
}

/// `debug.input` section `interactions`: the person's interactions (cmux's INP, p04-input-097) from the
/// same ledger as `latency`, folded up to the read: the count, the longest, the longest after ignoring
/// one for each 50, and the kind and target of the longest.
public nonisolated struct InteractionLatencyDebugSource: DebugInputSource {
    private let reporter: InputLatencyReporter

    /// - Parameter reporter: The input latency reporter whose ledger pairs the interactions.
    public init(reporter: InputLatencyReporter) {
        self.reporter = reporter
    }

    public var section: DebugInputSection { .interactions }

    public func read() async -> InputLatencySnapshot.Interactions {
        await reporter.snapshot().interactions
    }

    public func reset() async {
        await reporter.reset()
    }
}
