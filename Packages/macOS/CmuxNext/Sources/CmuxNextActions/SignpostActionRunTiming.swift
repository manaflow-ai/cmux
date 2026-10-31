import CmuxNextSignposts

/// The App's ``ActionRunTiming``: `action.perform` around the synchronous run and `action.commit`
/// from its start to the next Core Animation commit (``CommitBoundary``), plus `action.gate`
/// around a confirmation or argument gate, in Debug and Release. The message fields go to the log
/// system unformatted (``ActionSignpostMessage``). With a ``ActionBudgetMonitor``, each run's
/// perform-to-commit time also goes into the monitor's ring, read at the same commit boundary.
///
/// Built once at the composition root (`AppServices`) and passed to
/// ``ActionRegistry/standard(runTiming:)``; tests use ``NoActionRunTiming`` or a recorder.
public struct SignpostActionRunTiming: ActionRunTiming {
    private let wakes: RunLoopWakeWatch
    /// The per-action budget the runs are recorded into; nil records none.
    public let monitor: ActionBudgetMonitor?

    /// The always-on action signposts, with no budget monitor.
    public init() {
        self.init(monitor: nil)
    }

    /// The always-on action signposts, and every run recorded into `monitor`.
    ///
    /// - Parameter monitor: The per-action budget (``ActionBudgetMonitor``), or nil.
    public init(monitor: ActionBudgetMonitor?) {
        wakes = RunLoopWakeWatch()
        self.monitor = monitor
    }

    /// A run whose handler opened a person-driven nested run loop that waited (a menu's event
    /// tracking or a modal panel woke while the handler ran; ``RunLoopWakeWatch``) ends both
    /// intervals with `loop=nested`: they hold the person's dwell. A handler that waits in any other
    /// mode stays in the latency rows (a stall). A run started inside that loop is timed on its own.
    public func time<T>(_ key: ActionRunKey, _ origin: ActionOrigin, input: () -> ActionRunInput, _ body: () -> T) -> T {
        let id = key.id, index = key.index
        let signposter = Signposter.action
        let signposts = signposter.isEnabled
        guard signposts || monitor != nil else { return body() }
        let start = ActionBudgetMonitor.now()
        let span = monitor?.beginSpan(index, start: start)
        let read = input()
        let message = ActionSignpostMessage(id: id.rawValue, origin: origin.rawValue, inputAgeMilliseconds: read.ageMilliseconds)
        let commit = signposts ? signposter.begin(.actionCommit, message) : nil
        let perform = signposts ? signposter.begin(.actionPerform, message) : nil
        wakes.begin()
        let before = wakes.wakes
        let result = body()
        let nested = wakes.wakes != before
        wakes.end()
        if nested {
            monitor?.record(index, read.entrypoint, start: start, end: ActionBudgetMonitor.now(),
                            inputAgeMilliseconds: read.ageMilliseconds, outcome: .nested, span: span)
            if let perform { signposter.endSpanningNestedLoop(.actionPerform, perform) }
            if let commit { signposter.endSpanningNestedLoop(.actionCommit, commit) }
            return result
        }
        if let perform { signposter.end(.actionPerform, perform) }
        let monitor = monitor
        CommitBoundary().after { [signposter] outcome in
            // The clock first: the signpost's end and the monitor's write are not the run's time.
            let end = ActionBudgetMonitor.now()
            if let commit { signposter.end(.actionCommit, commit, outcome) }
            monitor?.record(index, read.entrypoint, start: start, end: end, inputAgeMilliseconds: read.ageMilliseconds,
                            outcome: outcome == .committed ? .committed : .missed, span: span)
        }
        return result
    }

    public func intern(_ id: ActionID) -> UInt32 {
        monitor?.intern(id) ?? 0
    }

    public func beginGate(_ id: ActionID, _ origin: ActionOrigin, input: () -> ActionRunInput) -> (@MainActor () -> Void)? {
        let signposter = Signposter.action
        guard signposter.isEnabled else { return nil }
        let message = ActionSignpostMessage(id: id.rawValue, origin: origin.rawValue, inputAgeMilliseconds: input().ageMilliseconds)
        let gate = signposter.begin(.actionGate, message)
        return { [signposter] in signposter.end(.actionGate, gate) }
    }
}
