/// A task an action handler started. Its value is nil on success, else
/// the failure (a daemon error) for callers that report it.
public typealias ActionWork = Task<String?, Never>

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
