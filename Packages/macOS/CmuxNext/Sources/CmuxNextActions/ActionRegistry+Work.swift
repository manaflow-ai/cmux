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

    public init(_ message: String, mayHaveApplied: Bool = false, terminalMayAppear: Bool = false) {
        self.message = message
        self.mayHaveApplied = mayHaveApplied
        self.terminalMayAppear = terminalMayAppear
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String { message }
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
    /// Reports a task a handler started. Ignored unless a caller is capturing.
    public func track(_ task: ActionWork) {
        if capturedWork != nil { capturedWork?.append(task) }
    }

    /// Runs `body` (a synchronous `perform`) and returns the tasks its
    /// handlers reported.
    public func capturingWork(_ body: () -> Void) -> [ActionWork] {
        let previous = capturedWork
        capturedWork = []
        body()
        let work = capturedWork ?? []
        capturedWork = previous.map { $0 + work }
        return work
    }
}
