// Target-aware "cannot run" reasons: an action that is available in general
// but not on one target (the screen's only column cannot be pinned) shows as
// disabled with the reason in that target's context menu, instead of failing
// after the click. `perform` refuses such an invocation with the reason, so
// the palette, the CLI and MCP report it too.
extension ActionRegistry {
    /// Sets the target-aware reason of a bound action.
    public func setTargetUnavailableReason(_ id: ActionID, _ reason: @escaping @MainActor (ActionInvocation) -> String?) {
        guard var action = action(for: id) else { return }
        action.targetUnavailableReason = reason
        register(action)
    }

    /// The general reason, else the reason for `invocation`'s target.
    public func unavailableReason(for id: ActionID, invocation: ActionInvocation) -> String? {
        unavailableReason(for: id) ?? action(for: id)?.targetUnavailableReason?(invocation)
    }

    /// `canPerform(_:)` for one invocation's target.
    public func canPerform(_ id: ActionID, invocation: ActionInvocation) -> Bool {
        canPerform(id) && action(for: id)?.targetUnavailableReason?(invocation) == nil
    }
}
