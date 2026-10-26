import CmuxNextCompat

/// Where the launch values go out of the process, apart from the launch time marks: a value is
/// a count, a CPU time or a name, never milliseconds since process start. The app's
/// `LaunchMarkSink` writes each as a `<name> <value>` line to the bench's pipe and as a
/// `launch.value` signpost, which the trace readers that place `launch.mark` events on the
/// launch timeline do not read.
public nonisolated protocol LaunchValueSink: Sendable {
    /// Sends the numeric value `number` of `name` (a page-in count, a CPU time in ms).
    func writeValue(name: String, number: Double)
    /// Sends the named value `label` of `name` (the temperature).
    func writeValue(name: String, label: String)
}

/// The launch counters of one process: the first sample of each counter milestone
/// (``StartupCounterReader``), kept for `debug.timings` and sent to a ``LaunchValueSink``.
/// `DebugTimings.markLaunch` calls ``read(atMilestone:)`` as its first statement, so the
/// mark's own work (its lock, its pipe write, its signpost) never reaches the counters.
///
/// The state is one short `Mutex` section per counter milestone (two per launch); a short
/// `Mutex` section is allowed on the main thread (plans/cmux-next/threading-model.md,
/// "Blocking rule for the two donating waits").
public nonisolated final class LaunchCounterLog: Sendable {
    /// What the launch has read so far.
    public nonisolated struct Snapshot: Sendable, Equatable {
        /// Nil until `run_loop_start` has read the page-ins.
        public var temperature: StartupTemperature?
        /// Each value in the order it was read.
        public var values: [StartupCounterReader.Sample.Value]

        public init(temperature: StartupTemperature? = nil, values: [StartupCounterReader.Sample.Value] = []) {
            self.temperature = temperature
            self.values = values
        }
    }

    private nonisolated struct State {
        var snapshot = Snapshot()
        var milestones: Set<String> = []
    }

    private let reader: StartupCounterReader
    private let sink: any LaunchValueSink
    private let state = Mutex(State())

    /// - Parameters:
    ///   - reader: The counter reader; tests pass one with fixed counters.
    ///   - sink: Where each first sample's values go.
    public init(reader: StartupCounterReader = StartupCounterReader(), sink: any LaunchValueSink) {
        self.reader = reader
        self.sink = sink
    }

    /// Reads `milestone`'s counters before anything else, keeps them when they are the
    /// milestone's first, and then sends them: the temperature first, then each value. A
    /// repeated milestone keeps the first sample and sends nothing.
    ///
    /// - Returns: The sample kept, or nil for a milestone that reads no counters or was read before.
    @discardableResult
    public func read(atMilestone milestone: String) -> StartupCounterReader.Sample? {
        guard let sample = reader.sample(atMilestone: milestone) else { return nil }
        let first = state.withLock { current in
            guard current.milestones.insert(milestone).inserted else { return false }
            if let temperature = sample.temperature { current.snapshot.temperature = temperature }
            current.snapshot.values.append(contentsOf: sample.values)
            return true
        }
        guard first else { return nil }
        if let temperature = sample.temperature {
            sink.writeValue(name: StartupCounterReader.temperatureName, label: temperature.rawValue)
        }
        for value in sample.values { sink.writeValue(name: value.name, number: value.value) }
        return sample
    }

    /// The temperature and the values read so far.
    public var snapshot: Snapshot { state.withLock { $0.snapshot } }
}
