public import CmuxNextActions
public import CmuxNextDaemon

// The daemon side of the action pipeline (plans/cmux-next/zero-latency.md, "Native actions: the
// budget contract"): a handler returns one of these effects, so its change shows on the input's
// turn and the registry, not the handler, sends the command and reports a failure.
extension DaemonService {
    /// Shows `intent` in the store now and returns the effect that sends `body`: the reply settles
    /// the intent, a failure takes it out of the store (the visible state returns exactly) and the
    /// registry shows why. The one shape for a daemon change the store can show first.
    ///
    /// - Parameters:
    ///   - label: The command's name in logs and the action scope (`rename-pane`).
    ///   - intent: The local change (``Intent``).
    ///   - body: The command.
    /// - Returns: ``ActionEffect/applied(_:)``.
    public func intentEffect(_ label: String, _ intent: Intent, _ body: @escaping DaemonCommandBody) -> ActionEffect {
        .applied(ActionConfirmation(send: intentSender(label, intent, body)))
    }

    /// Shows `intent` in the store now and returns the work that sends `body`: nil when it applied,
    /// else why it failed (the intent is out of the store again). For a change outside an action run
    /// (a sidebar click or drag) that reports its own failure.
    ///
    /// - Parameters:
    ///   - label: The command's name.
    ///   - intent: The local change (``Intent``).
    ///   - body: The command.
    /// - Returns: The send, to run after this turn.
    public func intentSender(_ label: String, _ intent: Intent, _ body: @escaping DaemonCommandBody)
        -> @MainActor () async -> ActionWorkFailure? {
        let send = intendNowReporting(label, intent, transaction: .generate(), body)
        return { [self] in
            switch await send() {
            case .success: return nil
            case .failure(let error): return self.workFailure(label, error)
            }
        }
    }

    /// The effect of a command whose local change the caller already showed outside the store (a
    /// sidebar row's color): `rollback` takes it back when the command fails.
    ///
    /// - Parameters:
    ///   - label: The command's name.
    ///   - rollback: Undoes the caller's local change.
    ///   - body: The command.
    /// - Returns: ``ActionEffect/applied(_:)``.
    public func commandEffect(_ label: String, rollback: @escaping @MainActor (ActionWorkFailure) -> Void,
                              _ body: @escaping DaemonCommandBody) -> ActionEffect {
        .applied(ActionConfirmation(send: sender(label, body), rollback: rollback))
    }

    /// The effect of a command that shows nothing until its reply (``ActionEffect/waiting(_:_:)``,
    /// reason ``ActionWait/daemonEcho``): counted, and refused for new code by the pre-push
    /// guardrail `action-wait`. Prefer ``intentEffect(_:_:_:)``.
    ///
    /// - Parameters:
    ///   - label: The command's name.
    ///   - body: The command.
    /// - Returns: ``ActionEffect/waiting(_:_:)``.
    // action-wait-allow: the shared constructor of the counted waiting effect; each caller is the debt.
    public func waitingEffect(_ label: String, _ body: @escaping DaemonCommandBody) -> ActionEffect {
        .waiting(.daemonEcho, sender(label, body)) // action-wait-allow: the shared constructor; each caller is the debt
    }

    /// Opens the command's ticket now (an action that awaits its scope waits for it from this turn)
    /// and returns the work that sends it.
    private func sender(_ label: String, _ body: @escaping DaemonCommandBody) -> @MainActor () async -> ActionWorkFailure? {
        let ticket = openTicket(label)
        return { [self] in await failure(label, ticket: ticket, body) }
    }
}
