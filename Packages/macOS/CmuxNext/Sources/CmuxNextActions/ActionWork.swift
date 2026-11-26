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
    /// More of a coded failure (``code``) for a caller to read, beside its reason: the control error's `data`
    /// (`until_at` for `agent.limit_reached`). Empty for every other failure.
    public var details: [String: String] = [:]
    /// The person already saw why it failed (the daemon service showed a pane-still-opening refusal when the command
    /// ended), so no reporter (the registry, a handler's own report) shows a second notice: once, never zero times or twice.
    public var shown = false
    /// Why it failed in the person's words and language, where `message` is the daemon's own error (a full disk:
    /// "the disk is full"); the notice a person's run shows uses it, a capturing caller still gets `message`. Nil: `message`.
    public var shownReason: String?
    /// Where `message` came from, which decides whether a person ever reads it (``notice(title:)``).
    public var cause: ActionWorkCause

    public init(_ message: String, mayHaveApplied: Bool = false, terminalMayAppear: Bool = false) {
        self.message = message
        self.mayHaveApplied = mayHaveApplied
        self.terminalMayAppear = terminalMayAppear
        cause = mayHaveApplied || terminalMayAppear ? .unanswered : .text
    }

    /// The handler refused in its background work; `message` is the reason.
    public init(refusal: ActionWorkRefusal, reason: String) {
        self.init(reason)
        self.refusal = refusal
    }

    /// A failure the control socket answers with error `code` and `reason`, and `details` in its `data`.
    public init(code: String, reason: String, details: [String: String] = [:]) {
        self.init(reason)
        self.code = code
        self.details = details
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
