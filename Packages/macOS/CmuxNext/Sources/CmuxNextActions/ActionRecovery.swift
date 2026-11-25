/// A way past an unavailable reason that only a person's own gesture may take: Sign In for a
/// signed-out Cloud action. The action keeps its reason, so the CLI, MCP, scripts and pages are
/// still refused with it. For a person, the palette and menus keep the row enabled (the palette
/// shows `note` under it), and a run calls `run` with the action and the person's invocation; it
/// takes the way past (signs in) and then runs the action itself.
public struct ActionRecovery {
    public var note: String
    public var run: @MainActor (_ action: ActionID, _ invocation: ActionInvocation) -> Void

    public init(note: String, run: @escaping @MainActor (_ action: ActionID, _ invocation: ActionInvocation) -> Void) {
        self.note = note
        self.run = run
    }
}

extension ActionRegistry {
    /// The recovery a person's run of `id` would take now: the action is available in this context
    /// but disabled by its own reason, the run is the person's (``ActionOrigin/user``, also for the
    /// run it is nested in), and a registered recovery answers that reason. Nil otherwise.
    public func personRecovery(for id: ActionID, _ invocation: ActionInvocation = ActionInvocation()) -> ActionRecovery? {
        guard !unavailableRecoveries.isEmpty, (ActionRunScope.current?.origin ?? invocation.origin) == .user,
              let action = action(for: id), isAvailable(id, for: invocation),
              let reason = action.unavailableReason?() else { return nil }
        let canonical = canonicalID(for: id)
        for recovery in unavailableRecoveries {
            if let found = recovery(canonical, reason) { return found }
        }
        return nil
    }
}
