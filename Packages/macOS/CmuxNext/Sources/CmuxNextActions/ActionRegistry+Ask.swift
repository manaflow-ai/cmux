extension ActionRegistry {
    /// Asks the person for `ask.argument` of `id` inline in Cmd-Shift-P, then runs `id` with
    /// `invocation` plus the answer. A handler calls it when a run lacks a value it needs from a
    /// person (a menu Rename with no name), instead of presenting a separate dialog.
    ///
    /// - Parameters:
    ///   - id: The action to run once the argument is given.
    ///   - invocation: The run so far; its target pins the object the answer applies to.
    ///   - ask: The argument and the text its step starts from.
    /// - Returns: False when no palette is installed (a test or a headless process).
    @discardableResult
    public func ask(_ id: ActionID, _ invocation: ActionInvocation, _ ask: ActionArgumentAsk) -> Bool {
        guard let argumentAsker else { return false }
        argumentAsker(id, invocation, ask)
        return true
    }
}
