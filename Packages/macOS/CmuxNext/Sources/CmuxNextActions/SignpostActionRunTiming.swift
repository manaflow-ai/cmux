public import CmuxNextWakeups
import CmuxNextSignposts
public import CmuxNextTrace

/// The App's ``ActionRunTiming``: `action.perform` around the synchronous run and `action.commit`
/// from its start to the next Core Animation commit (``CommitBoundary``), plus `action.gate`
/// around a confirmation or argument gate, in Debug and Release. The message fields go to the log
/// system unformatted (``ActionSignpostMessage``). With a ``ActionBudgetMonitor``, each run's
/// perform-to-commit time also goes into the monitor's ring, read at the same commit boundary, and a
/// committed run's estimated present goes to `action.presented_estimate`
/// (``ActionBudgetMonitor/recordPresentEstimate(_:start:commitEnd:inputAgeMilliseconds:)``).
///
/// Built once at the composition root (`AppServices`) and passed to
/// ``ActionRegistry/standard(runTiming:)``; tests use ``NoActionRunTiming`` or a recorder.
public struct SignpostActionRunTiming: ActionRunTiming {
    private let wakes: RunLoopWakeWatch
    /// The per-action budget the runs are recorded into; nil records none.
    public let monitor: ActionBudgetMonitor?
    /// The app's crash keys: each run sets ``CrashKeySlots/Key/actionID`` for its synchronous work and puts the
    /// outer value back after it; nil sets none.
    public let crashKeys: CrashKeySlots?
    /// The process's crash-key page: each run sets ``CrashKeySlot/actionIndex`` and
    /// ``CrashKeySlot/actionEntrypoint`` for its synchronous work and puts the outer run's back after it; nil
    /// sets none.
    public let crashKeyPage: CrashKeyPage?

    /// The always-on action signposts, with no budget monitor.
    public init() {
        self.init(monitor: nil)
    }

    /// The always-on action signposts, and every run recorded into `monitor` and named in `crashKeys`.
    ///
    /// - Parameters:
    ///   - monitor: The per-action budget (``ActionBudgetMonitor``), or nil.
    ///   - crashKeys: The app's crash keys, or nil.
    ///   - crashKeyPage: The process's crash-key page (`TraceBlackBox.crashKeys`), or nil.
    public init(monitor: ActionBudgetMonitor?, crashKeys: CrashKeySlots? = nil, crashKeyPage: CrashKeyPage? = nil) {
        wakes = RunLoopWakeWatch()
        self.monitor = monitor
        self.crashKeys = crashKeys
        self.crashKeyPage = crashKeyPage
    }

    /// A run whose handler opened a person-driven nested run loop that waited (a menu's event
    /// tracking or a modal panel woke while the handler ran; ``RunLoopWakeWatch``) ends both
    /// intervals with `loop=nested`: they hold the person's dwell. A handler that waits in any other
    /// mode stays in the latency rows (a stall). A run started inside that loop is timed on its own.
    public func time<T>(_ key: ActionRunKey, _ origin: ActionOrigin, input: () -> ActionRunInput, _ body: () -> T) -> T {
        // Around the timing too, so a crash in the timing's own bookkeeping names the run.
        if let page = crashKeyPage {
            // Read once, here, and handed to the timing. The page's entrypoint is the trace position + 1 (0: no run).
            let read = input()
            return page.withKey(.actionIndex, CrashKeySlots.stableKey(key.id.rawValue)) {
                page.withKey(.actionEntrypoint, UInt64(read.entrypoint.tracePosition) + 1) { named(key, origin, input: { read }, body) }
            }
        }
        return named(key, origin, input: input, body)
    }

    /// The run with ``CrashKeySlots/Key/actionID`` set when there are crash keys.
    private func named<T>(_ key: ActionRunKey, _ origin: ActionOrigin, input: () -> ActionRunInput, _ body: () -> T) -> T {
        guard let crashKeys else { return timed(key, origin, input: input, body) }
        return crashKeys.withKey(.actionID, CrashKeySlots.stableKey(key.id.rawValue)) { timed(key, origin, input: input, body) }
    }

    private func timed<T>(_ key: ActionRunKey, _ origin: ActionOrigin, input: () -> ActionRunInput, _ body: () -> T) -> T {
        let id = key.id, index = key.index
        let signposter = Signposter.action
        let signposts = signposter.isEnabled
        guard signposts || monitor != nil else { return body() }
        let start = ActionBudgetMonitor.now()
        let span = monitor?.beginSpan(index, start: start)
        let read = input()
        let message = ActionSignpostMessage(id: id.rawValue, origin: origin.rawValue, inputAgeMilliseconds: read.ageMilliseconds)
        let entrypoint = read.entrypoint.tracePosition
        let commit = signposts ? signposter.begin(.actionCommit, message, actionIndex: index, entrypoint: entrypoint) : nil
        let perform = signposts ? signposter.begin(.actionPerform, message, actionIndex: index, entrypoint: entrypoint) : nil
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
            // A missed commit's end is idle time, not the commit: it gets no estimated present.
            if signposts, outcome == .committed {
                monitor?.recordPresentEstimate(index, start: start, commitEnd: end, inputAgeMilliseconds: read.ageMilliseconds)
            }
            if outcome == .committed { monitor?.onCommit?(index, read.entrypoint) }
        }
        return result
    }

    public func intern(_ id: ActionID) -> UInt32 {
        monitor?.intern(id) ?? 0
    }

    public func beginGate(_ id: ActionID, _ origin: ActionOrigin, input: () -> ActionRunInput) -> (@MainActor () -> Void)? {
        let signposter = Signposter.action
        guard signposter.isEnabled else { return nil }
        let read = input()
        let message = ActionSignpostMessage(id: id.rawValue, origin: origin.rawValue, inputAgeMilliseconds: read.ageMilliseconds)
        // A gate has no run key (``ActionRunTiming/beginGate(_:_:input:)`` takes the id, and interning is
        // bind-time only), so its record carries the entrypoint and index 0, "none interned".
        let gate = signposter.begin(.actionGate, message, actionIndex: 0, entrypoint: read.entrypoint.tracePosition)
        return { [signposter] in signposter.end(.actionGate, gate) }
    }
}
