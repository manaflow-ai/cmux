/// Times action runs for ``ActionRegistry``: the seam between the registry and the always-on
/// `action.perform` / `action.commit` / `action.gate` signposts.
///
/// The App passes ``SignpostActionRunTiming`` at the composition root (`AppServices`); the
/// registry's default is ``NoActionRunTiming``, so a unit test's registry writes no signposts and
/// adds no run-loop observer. Tests pass a recorder to prove every run that does work is timed.
public protocol ActionRunTiming {
    /// Runs `body`, the run's synchronous work, inside the timing (`action.perform`, and
    /// `action.commit` from its start to the next Core Animation commit).
    ///
    /// - Parameters:
    ///   - key: The action: its id and the index ``intern(_:)`` gave it.
    ///   - origin: Who started the run.
    ///   - input: The age of the person's input event the run answers (or -1) and the run's
    ///     entrypoint; called at most once, only when the timing records.
    ///   - body: The run.
    /// - Returns: What `body` returns.
    func time<T>(_ key: ActionRunKey, _ origin: ActionOrigin, input: () -> ActionRunInput, _ body: () -> T) -> T

    /// The index the timing records `id`'s runs under (``ActionBudgetMonitor/intern(_:)``). The
    /// registry asks once per action, when the action is bound, so a run carries the index and
    /// its timing looks nothing up. A timing that keeps no per-action record returns 0.
    ///
    /// - Parameter id: The action.
    /// - Returns: Its index.
    func intern(_ id: ActionID) -> UInt32

    /// Begins the timing of a gate (`action.gate`): the confirmation presenter or the argument
    /// collector deciding whether and when the action runs. A gate is not a run of the action:
    /// its time is kept out of the action's own rows, and the run it lets through is timed by
    /// ``time(_:_:input:_:)`` on its own.
    ///
    /// - Parameters:
    ///   - id: The gated action.
    ///   - origin: Who started the run.
    ///   - input: As for ``time(_:_:input:_:)``.
    /// - Returns: The end of the gate's interval, or nil when nothing records. The registry
    ///   calls it exactly once: when the gate returns, or earlier, when the gate starts a timed
    ///   run or gate synchronously, so a gate never encloses another interval.
    func beginGate(_ id: ActionID, _ origin: ActionOrigin, input: () -> ActionRunInput) -> (@MainActor () -> Void)?
}

/// An ``ActionRunTiming`` that records nothing: the default of a registry built without one
/// (unit tests, previews). Runs `body` as is.
public struct NoActionRunTiming: ActionRunTiming {
    /// A timing that records nothing.
    public init() {}

    public func time<T>(_ key: ActionRunKey, _ origin: ActionOrigin, input: () -> ActionRunInput, _ body: () -> T) -> T {
        body()
    }

    public func intern(_ id: ActionID) -> UInt32 { 0 }

    public func beginGate(_ id: ActionID, _ origin: ActionOrigin, input: () -> ActionRunInput) -> (@MainActor () -> Void)? {
        nil
    }
}
