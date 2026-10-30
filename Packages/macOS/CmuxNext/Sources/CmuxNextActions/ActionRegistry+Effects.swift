import CmuxNextWakeups

// The action pipeline (plans/cmux-next/zero-latency.md, "Native actions: the budget contract"): a
// handler returns its synchronous change as an ``ActionEffect``; the registry, not the handler,
// starts the remote work after the handler returned, tracks it, reconciles and rolls back.
extension ActionRegistry {
    /// Binds a handler that returns what its synchronous part did. Prefer it to the `bind` family
    /// (`invoke:`, `handler:`; its own name, so a trailing closure never picks the wrong one): the type says whether the action waits, and the registry owns the send,
    /// the rollback and the failure notice.
    ///
    /// - Parameters:
    ///   - id: A catalog action.
    ///   - isEnabled: Whether it can run now.
    ///   - effect: The handler: applies the visible change and returns the rest as a value.
    /// - Returns: False when `id` is not in the catalog.
    @discardableResult
    public func bindEffect(_ id: ActionID, isEnabled: @escaping @MainActor () -> Bool = { true },
                           effect: @escaping @MainActor (ActionInvocation) -> ActionEffect) -> Bool {
        guard let descriptor = descriptor(for: id) else { return false }
        noteBinding(descriptor.id, placeholder: false)
        register(Action(id: descriptor.id, title: descriptor.title, keywords: descriptor.keywords, isEnabled: isEnabled,
                        handler: {}).withEffect(effect))
        return true
    }

    /// ``bindEffect(_:isEnabled:effect:)`` whose availability depends on `reason`, as
    /// ``bind(_:unavailable:invoke:)``.
    @discardableResult
    public func bindEffect(_ id: ActionID, unavailable reason: @escaping @MainActor () -> String?,
                           effect: @escaping @MainActor (ActionInvocation) -> ActionEffect) -> Bool {
        guard let descriptor = descriptor(for: id) else { return false }
        noteBinding(descriptor.id, placeholder: false)
        register(Action(id: descriptor.id, title: descriptor.title, keywords: descriptor.keywords, isEnabled: { reason() == nil },
                        unavailableReason: reason, handler: {}).withEffect(effect))
        return true
    }

    /// Bound actions whose handler returns an ``ActionEffect``; the rest (``legacyBoundCount``) are
    /// untyped `invoke:` / `handler:` binds whose waits the type cannot show.
    public var effectBoundCount: Int { actions.reduce(0) { $0 + ($1.effect == nil ? 0 : 1) } }

    /// Bound actions with an untyped handler.
    public var legacyBoundCount: Int { actions.count - effectBoundCount }

    /// Runs what an effect asks for: nothing more for ``ActionEffect/done``, the remote work for
    /// ``ActionEffect/applied(_:)`` and ``ActionEffect/waiting(_:_:)``, the refusal for
    /// ``ActionEffect/refused(_:quiet:)``. The registry calls it after every handler run; a direct
    /// gesture outside an action run (the screen bar's inline rename) calls it with its own effect.
    ///
    /// - Parameters:
    ///   - effect: The handler's result.
    ///   - id: The action.
    ///   - invocation: The run.
    public func settle(_ effect: ActionEffect, of id: ActionID, _ invocation: ActionInvocation) {
        switch effect.kind {
        case .done:
            effectExpectsFrame()
        case .applied(let confirmation):
            effectExpectsFrame()
            start(id, invocation, confirmation.send, rollback: confirmation.rollback)
        case .waiting(let reason, let work):
            effectExpectsFrame()
            waitingRuns[canonicalID(for: id), default: [:]][reason, default: 0] += 1
            start(id, invocation, work, rollback: nil)
        case .refused(let reason, let quiet):
            refuse(reason, quiet: quiet)
        }
    }

    /// A legacy handler's remote work whose local change (an optimistic create's stand-in) the store already rolls
    /// back when it fails: tracked for a capturing caller, which reports the failure itself; otherwise the failure
    /// shows where refusals show and is logged (``remoteFailureObserver``), as an ``ActionEffect/applied(_:)`` one does.
    /// A refusal is never silent (P0 2026-10-30: a refused second Cmd-D's pane just vanished).
    public func trackRollingBack(_ id: ActionID, _ work: ActionWork) {
        let reported = isCapturingWork
        let title = title(for: id) ?? id.rawValue
        let cause = (ActionRunScope.current?.origin ?? .user).observationCause
        let mainWork = self.mainWork
        // main-hop-allow: the task only awaits `work` (the caller's own task); the notice is posted through mainWork.reply in the run's class, as `start` posts it
        track(Task { [weak self] in
            guard let failure = await work.value else { return nil }
            guard !reported, !failure.shown else { return failure }
            let notice: @MainActor () -> Void = { self?.remoteFailureObserver?(id, failedText(title, failure)) }
            if let mainWork { await mainWork.reply(as: cause, owner: "ActionRegistry.rollbackNotice") { notice() } } else { notice() }
            return failure
        })
    }

    /// Starts `send` after the handler's turn, tracked for a capturing caller; on failure rolls back
    /// and, unless a capturing caller reports it itself, shows it.
    ///
    /// The completion (the rollback and notice, and for a run started in a person's input the
    /// answer to that input) runs under the run's cause through ``mainWork``
    /// (``MainWorkScheduler/reply(as:owner:file:line:_:)``). A person's run is the rest of the
    /// person's action (Chrome `base::TaskPriority::USER_BLOCKING`, base/task/task_traits.h): its
    /// remote half runs at ``WorkPriority/userBlocking`` and its completion as one
    /// ``MainWorkClass/userBlocking`` task, ahead of visible work and not held by the input response
    /// it answers; that task's commit closes the response (``MainFrameBudget/noteAnswered(_:)``).
    private func start(_ id: ActionID, _ invocation: ActionInvocation, _ send: @escaping @MainActor () async -> ActionWorkFailure?,
                       rollback: (@MainActor (ActionWorkFailure) -> Void)?) {
        let reported = isCapturingWork
        let title = title(for: id) ?? id.rawValue
        let cause = (ActionRunScope.current?.origin ?? invocation.origin).observationCause
        let mainWork = self.mainWork
        let answers = cause == .person ? mainWork?.budget.answerableInput : nil
        // main-hop-allow: `send` is the handler's main-actor async body; the Task only starts it at the run's priority, and its completion is posted through mainWork.reply in the run's class
        let task: ActionWork = Task(priority: cause == .person ? WorkPriority.userBlocking.taskPriority : nil) { [weak self] in
            let failure = await send()
            guard failure != nil || answers != nil else { return nil }
            let complete: @MainActor () -> Void = {
                if let failure {
                    rollback?(failure)
                    if !reported, !failure.shown { self?.remoteFailureObserver?(id, failedText(title, failure)) }
                }
                if let answers { mainWork?.budget.noteAnswered(answers) }
            }
            if let mainWork {
                await mainWork.reply(as: cause, owner: "ActionRegistry.completion") { complete() }
            } else {
                complete()
            }
            return failure
        }
        track(task)
    }
}

/// The notice for a failed remote half (Localizable.xcstrings).
private func failedText(_ title: String, _ failure: ActionWorkFailure) -> String {
    // A typed refusal (the pane is still opening) is already the person's sentence; a daemon error gets its frame.
    if failure.refusal != nil { return failure.message }
    return failedText(title, failure.message)
}

private func failedText(_ title: String, _ reason: String) -> String {
    String(format: String(localized: "action.effect.failed", defaultValue: "%1$@ did not apply: %2$@", bundle: .module), title, reason)
}
