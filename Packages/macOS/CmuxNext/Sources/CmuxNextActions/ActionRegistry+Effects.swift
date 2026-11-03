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
            return
        case .applied(let confirmation):
            start(id, invocation, confirmation.send, rollback: confirmation.rollback)
        case .appliedResult(let result):
            let reported = isCapturingWork
            let title = title(for: id) ?? id.rawValue
            track(result: Task { [weak self] in
                let answer = await result()
                if case .failure(let failure) = answer, !reported, !failure.shown {
                    self?.remoteFailureObserver?(id, failedText(title, failure))
                }
                return answer
            })
        case .waiting(let reason, let work):
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
        // task-owner: reports `work`'s failure once it ends; `work` itself is the caller's.
        track(Task { [weak self] in
            guard let failure = await work.value else { return nil }
            if !reported, !failure.shown { self?.remoteFailureObserver?(id, failedText(title, failure)) }
            return failure
        })
    }

    /// Starts `send` after the handler's turn, tracked for a capturing caller; on failure rolls back
    /// and, unless a capturing caller reports it itself, shows it.
    private func start(_ id: ActionID, _ invocation: ActionInvocation, _ send: @escaping @MainActor () async -> ActionWorkFailure?,
                       rollback: (@MainActor (ActionWorkFailure) -> Void)?) {
        let reported = isCapturingWork
        let title = title(for: id) ?? id.rawValue
        let task: ActionWork = Task { [weak self] in
            guard let failure = await send() else { return nil }
            rollback?(failure)
            if !reported, !failure.shown { self?.remoteFailureObserver?(id, failedText(title, failure)) }
            return failure
        }
        track(task)
    }

    /// Shows that the remote half of a change made outside an action run (a sidebar click, drag or
    /// inline edit, #26382) failed and its local change was taken back: the notice a failed effect
    /// shows, titled `title`, else the action's own title.
    ///
    /// - Parameters:
    ///   - id: The action the change stands for.
    ///   - title: The change's name when the action's title does not say it (a drag says "Move").
    ///   - failure: Why it failed.
    public func reportFailure(of id: ActionID, title: String? = nil, _ failure: ActionWorkFailure) {
        remoteFailureObserver?(id, failedText(title ?? self.title(for: id) ?? id.rawValue, failure.shownReason ?? failure.message))
    }

    /// Reports `task`, the daemon half of action `id`, to a capturing caller (a CLI, socket or MCP run awaits it and gets
    /// the typed failure, ``track(_:)``). A run nobody waits on (keyboard, menu, palette) shows its failure once where a
    /// failed change shows ("<action> did not apply: <reason>"), unless the person already saw it
    /// (``ActionWorkFailure/shown``): a person's New Workspace refused on a full disk showed nothing (restore fuzz h3).
    public func trackOrReport(_ task: ActionWork, as id: ActionID) {
        if isCapturingWork { return track(task) }
        // task-owner: one-shot; ends with `task`, and holds the registry weakly.
        Task { @MainActor [weak self] in
            guard let self, let failure = await task.value, !failure.shown else { return }
            remoteFailureObserver?(id, failedText(title(for: id) ?? id.rawValue, failure))
        }
    }
}

/// The notice for a failed remote half (Localizable.xcstrings).
private func failedText(_ title: String, _ failure: ActionWorkFailure) -> String {
    // A typed refusal (the pane is still opening) is already the person's sentence; a daemon error gets its frame.
    if failure.refusal != nil { return failure.message }
    return failedText(title, failure.shownReason ?? failure.message)
}

private func failedText(_ title: String, _ reason: String) -> String {
    String(format: String(localized: "action.effect.failed", defaultValue: "%1$@ did not apply: %2$@", bundle: .module), title, reason)
}
