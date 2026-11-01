/// A task an action handler started. Its value is nil on success, else
/// the failure (a daemon error) for callers that report it.
public typealias ActionWork = Task<ActionWorkFailure?, Never>

/// Why the asynchronous work of an action failed. A string literal or
/// interpolation makes a plain failure.
public struct ActionWorkFailure: Error, Sendable, Hashable, CustomStringConvertible, ExpressibleByStringInterpolation {
    public var message: String
    /// A command that starts a terminal missed its deadline. The daemon may
    /// still create the terminal, so a caller must not simply retry.
    public var terminalMayAppear: Bool
    /// The command's reply missed its deadline: it may still apply, so a
    /// caller must not simply retry.
    public var mayHaveApplied: Bool
    /// A typed refusal from the handler's own work, not a daemon failure: the control socket
    /// answers it as it answers the same refusal reported at once (`unavailable` with the
    /// reason, or `not_found`). Nil for a daemon failure (`daemon_error`).
    public var refusal: ActionWorkRefusal?
    /// The control error code a caller answers instead of the default
    /// (`screenshot.unavailable`), with `message` as its reason. Nil for the
    /// default mapping (``refusal``, a timeout, or `daemon_error`).
    public var code: String?
    /// The person already saw why it failed (the daemon service showed a pane-still-opening refusal when the command
    /// ended), so no reporter (the registry, a handler's own report) shows a second notice: once, never zero times or twice.
    public var shown = false
    /// Why it failed in the person's words and language, where `message` is the daemon's own error (a full disk:
    /// "the disk is full"); the notice a person's run shows uses it, a capturing caller still gets `message`. Nil: `message`.
    public var shownReason: String?

    public init(_ message: String, mayHaveApplied: Bool = false, terminalMayAppear: Bool = false) {
        self.message = message
        self.mayHaveApplied = mayHaveApplied
        self.terminalMayAppear = terminalMayAppear
    }

    /// The handler refused in its background work; `message` is the reason.
    public init(refusal: ActionWorkRefusal, reason: String) {
        self.init(reason)
        self.refusal = refusal
    }

    /// A failure the control socket answers with error `code` and `reason`.
    public init(code: String, reason: String) {
        self.init(reason)
        self.code = code
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String { message }
}

/// How a refusal from an action's background work reaches a caller (``ActionRegistry/refuse(_:quiet:)``
/// and ``ActionRegistry/refuseNotFound(_:)`` for a refusal made at once).
public nonisolated enum ActionWorkRefusal: Sendable, Hashable {
    /// The action cannot act now (`unavailable`).
    case unavailable
    /// An explicit target names nothing (`not_found`).
    case notFound
}

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
        Task { @MainActor [weak self] in if let failure = await task.value { self?.refuse(failure.message) } }
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
