/// A wait an effect-bound handler hid behind a typed effect (``ActionRegistry/hiddenWaitRuns``): the
/// runtime count of what the pre-push guardrail `action-wait` cannot see on one line (a helper the
/// handler calls, a confirmation built elsewhere).
public nonisolated enum ActionHiddenWait: String, Sendable, Hashable, CaseIterable {
    /// The handler started remote work itself while it ran (a `daemon.send` / `ctx.send`, a tracked
    /// task): the run counts as effect-bound, but nothing it sent shows until the daemon echoes.
    case handlerSend
    /// An ``ActionEffect/applied(_:)`` whose ``ActionConfirmation`` has no rollback and is not a
    /// store intent: either no local change showed first (the send is the whole action) or a
    /// failure leaves the change shown.
    case unconfirmedApply
}
