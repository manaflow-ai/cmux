import CmuxNextCompat

/// Where the launch values go out of the process, apart from the launch time marks: a value is
/// a count or a CPU time, never milliseconds since process start. ``LaunchMarkSink`` writes each
/// as a `<name> <value>` line to the bench's pipe and as a `launch.value` signpost, which the trace
/// readers that place `launch.mark` events on the launch timeline do not read.
public nonisolated protocol LaunchValueSink: Sendable {
    /// Sends the numeric value `number` of `name` (a page-in count, a CPU time in ms).
    func writeValue(name: String, number: Double)
}

/// The launch counters of one process: the first frame's sample (``StartupCounterReader``), kept for
/// `debug.timings` and sent to a ``LaunchValueSink``. `DebugTimings.markLaunch` calls ``read(atMilestone:)``
/// as its first statement, so the mark's own work (its lock, its pipe write, its signpost) never reaches
/// the counters.
///
/// The state is one short `Mutex` section per counter milestone (one per launch); a short `Mutex` section
/// is allowed on the main thread (plans/cmux-next/threading-model.md, "Blocking rule for the two donating
/// waits").
public nonisolated final class LaunchCounterLog: Sendable {
    private nonisolated struct State {
        var values: [StartupCounterReader.Value] = []
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

    /// Reads `milestone`'s counters before anything else, keeps them when they are the milestone's first,
    /// and then sends each value. A repeated milestone keeps the first sample and sends nothing.
    ///
    /// - Returns: The values kept, or nil for a milestone that reads no counters or was read before.
    @discardableResult
    public func read(atMilestone milestone: String) -> [StartupCounterReader.Value]? {
        guard let values = reader.sample(atMilestone: milestone) else { return nil }
        let first = state.withLock { current in
            guard current.milestones.insert(milestone).inserted else { return false }
            current.values.append(contentsOf: values)
            return true
        }
        guard first else { return nil }
        for value in values { sink.writeValue(name: value.name, number: value.value) }
        return values
    }

    /// The values read so far, in the order they were read.
    public var values: [StartupCounterReader.Value] { state.withLock { $0.values } }
}
