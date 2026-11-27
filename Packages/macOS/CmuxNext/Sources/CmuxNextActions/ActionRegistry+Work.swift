
/// Completion of the asynchronous work an action starts.
///
/// Handlers stay synchronous: they apply local state and start daemon
/// commands without awaiting them. A caller that must answer only after
/// the effect exists (the control socket's `action.run` and the cmux CLI
/// compat layer) runs `perform` inside `capturingWork` and awaits the
/// tasks the handlers reported with `track(_:)`. Keyboard, menu, and
/// palette runs capture nothing, so tracking costs them nothing.
extension ActionRegistry {
    /// Whether a caller awaits the work handlers report (`capturingWork`). A handler whose
    /// failure would otherwise go unseen (a palette run) shows it itself when this is false.
    public var isCapturingWork: Bool { capturedWork != nil }

    /// Reports a task a handler started. Ignored unless a caller is capturing.
    public func track(_ task: ActionWork) {
        if capturedWork != nil { capturedWork?.append(task) }
    }

    /// Reports `task` to a capturing caller (a CLI or MCP run awaits it, ``track(_:)``); a menu or
    /// keyboard run nobody waits on shows its failure as a refusal (``refuse(_:quiet:)``) instead of
    /// dropping it (Archive Chief on an unreachable Chief did nothing).
    public func trackOrRefuse(_ task: ActionWork) {
        if isCapturingWork { return track(task) }
        // task-owner: one-shot; ends with `task`, and holds the registry weakly.
        Task { @MainActor [weak self] in if let failure = await task.value { self?.refuse(failure: failure) } }
    }

    /// Reports `failure`, the background half of a run nobody waits on, as a refusal: its notice where one is shown
    /// (``ActionWorkFailure/notice(title:)``), and only its `message` to a capturing caller and the log when the person
    /// can do nothing with it (a missed deadline, a dropped connection, the daemon's own text). Every handler that
    /// shows an ``ActionWorkFailure`` goes through here, never `refuse(failure.message)` (`ActionWorkFailureNoticeTests` checks the sources).
    public func refuse(failure: ActionWorkFailure) {
        if let notice = failure.notice(title: nil) { refuse(notice) } else { refuse(failure.message, quiet: true) }
    }

    /// Reports a task that produces the action's value (a screenshot's
    /// path and size): a capturing caller awaits it like ``track(_:)`` work
    /// and answers its fields (`action.run` `result`). Ignored unless a
    /// caller is capturing.
    public func track(result task: ActionResultWork) {
        guard capturedWork != nil else { return }
        capturedWork?.append(Task {
            if case .failure(let failure) = await task.value { return failure }
            return nil
        })
        capturedResults?.append(task)
    }

    /// Runs `body` (a synchronous `perform`) and returns the tasks its
    /// handlers reported.
    public func capturingWork(_ body: () -> Void) -> [ActionWork] {
        capturingRun(body).work
    }

    /// Runs `body` (a synchronous `perform`) and returns the tasks its
    /// handlers reported: all of their work, and the value-producing tasks
    /// among them (``track(result:)``).
    public func capturingRun(_ body: () -> Void) -> (work: [ActionWork], results: [ActionResultWork]) {
        let previous = capturedWork, previousResults = capturedResults
        capturedWork = []
        capturedResults = []
        body()
        let work = capturedWork ?? [], results = capturedResults ?? []
        capturedWork = previous.map { $0 + work }
        capturedResults = previousResults.map { $0 + results }
        return (work, results)
    }
}
