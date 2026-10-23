/// Times one action run for ``ActionRegistry``: the seam between the registry and the always-on
/// `action.perform` / `action.commit` signposts (``SignpostActionRunTiming``). Tests pass a
/// recorder to prove every run that does work is timed.
protocol ActionRunTiming {
    /// Runs `body`, the run's synchronous work, inside the timing.
    ///
    /// - Parameters:
    ///   - id: The action.
    ///   - origin: Who started the run.
    ///   - inputAge: The age in milliseconds of the OS input event being dispatched for the run,
    ///     or -1; called at most once, only when the timing records.
    ///   - body: The run.
    /// - Returns: What `body` returns.
    func time<T>(_ id: ActionID, _ origin: ActionOrigin, inputAge: () -> Double, _ body: () -> T) -> T
}
