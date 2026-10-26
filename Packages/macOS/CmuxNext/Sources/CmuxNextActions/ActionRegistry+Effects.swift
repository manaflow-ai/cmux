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

    /// Starts `send` after the handler's turn, tracked for a capturing caller; on failure rolls back
    /// and, unless a capturing caller reports it itself, shows it.
    ///
    /// A person's run (its effective origin is the person's, ``ActionOrigin/observationCause``) is
    /// the rest of the person's action (Chrome `base::TaskPriority::USER_BLOCKING`,
    /// base/task/task_traits.h): its remote half runs at ``WorkPriority/userBlocking``, and its
    /// completion runs as one ``MainWorkClass/userBlocking`` task on ``mainWork``, ahead of visible
    /// work and not held by the input response it answers.
    private func start(_ id: ActionID, _ invocation: ActionInvocation, _ send: @escaping @MainActor () async -> ActionWorkFailure?,
                       rollback: (@MainActor (ActionWorkFailure) -> Void)?) {
        let reported = isCapturingWork
        let title = title(for: id) ?? id.rawValue
        let isPerson = (ActionRunScope.current?.origin ?? invocation.origin).observationCause == .person
        let completions = isPerson ? mainWork : nil
        let task: ActionWork = Task(priority: isPerson ? WorkPriority.userBlocking.taskPriority : nil) { [weak self] in
            guard let failure = await send() else { return nil }
            let complete: @MainActor () -> Void = {
                rollback?(failure)
                if !reported { self?.remoteFailureObserver?(id, failedText(title, failure.message)) }
            }
            if let completions {
                await completions.apply(.userBlocking, owner: "ActionRegistry.completion") { complete() }
            } else {
                complete()
            }
            return failure
        }
        track(task)
    }
}

/// The notice for a failed remote half (Localizable.xcstrings).
private func failedText(_ title: String, _ reason: String) -> String {
    String(format: String(localized: "action.effect.failed", defaultValue: "%1$@ did not apply: %2$@", bundle: .module), title, reason)
}
