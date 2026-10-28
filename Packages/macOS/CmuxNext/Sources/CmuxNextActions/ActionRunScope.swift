/// The view-change permission of the action run in progress
/// (plans/cmux-next/OWNERSHIP-PRINCIPLES.md, "Clients are projections").
///
/// `ActionRegistry.perform` binds it as a task local for the handler, so
/// every task the handler starts inherits it and an async continuation of
/// the run (after a daemon reply) still sees its own permission. Code that
/// changes focus, selection, the shown workspace or the key window asks
/// ``ActionRunScope/viewChangeAllowed()`` instead of reading a flag that is only
/// true for the synchronous extent of a run.
public nonisolated struct ActionRunScope: Sendable, Hashable {
    /// The run whose handler (or a task it started) is running, or nil
    /// outside action runs (a direct gesture: a click, a drag).
    @TaskLocal public static var current: ActionRunScope?

    public var origin: ActionOrigin
    /// The run may change this client's view: origin `user`, `focus: true`,
    /// or an action whose purpose is the view change (`focuses`).
    public var allowsViewChange: Bool

    public init(origin: ActionOrigin, allowsViewChange: Bool) {
        self.origin = origin
        self.allowsViewChange = allowsViewChange
    }

    /// The scope of a run of an action described as `focuses` (or not).
    public init(_ invocation: ActionInvocation, focuses: Bool) {
        self.init(origin: invocation.origin, allowsViewChange: invocation.allowsViewChange || focuses)
    }

    /// This scope as a run started inside `outer`: a handler that runs
    /// another action never gains a permission its own run lacks (an inner
    /// run is built with the default user origin).
    public func nested(in outer: ActionRunScope?) -> ActionRunScope {
        guard let outer else { return self }
        return ActionRunScope(origin: outer.origin, allowsViewChange: outer.allowsViewChange && allowsViewChange)
    }
}

/// The one question every focus, selection, shown-workspace and key-window
/// change asks before it happens.
public extension ActionRunScope {
    /// Whether the code running now may change this client's view: the
    /// current run's permission, else true (no run: a direct gesture of
    /// this client's user).
    nonisolated static func viewChangeAllowed() -> Bool {
        ActionRunScope.current?.allowsViewChange ?? true
    }

    /// Runs `body` with `scope` bound. For a callback stored by a run and
    /// called later outside its task tree (a store waiter, a placement
    /// continuation): it keeps the permission of the run that stored it.
    /// The binding is made inside a task (`TaskLocal.withValueInTask`).
    @MainActor
    static func carrying<T>(_ scope: ActionRunScope?, _ body: () -> T) -> T {
        ActionRunScope.$current.withValueInTask(scope, operation: body)
    }
}

extension ActionRegistry {
    /// Runs `action`'s handler with its run scope bound as a task local, so
    /// the tasks the handler starts keep the run's view-change permission,
    /// inside the App's `invocationScope` (daemon routing). A gesture runs it
    /// where no task is current, so the binding is made inside a task
    /// (`TaskLocal.withValueInTask`, cx-bpcj).
    func runScoped(_ action: Action, _ id: ActionID, _ invocation: ActionInvocation) {
        let run = ActionRunScope(invocation, focuses: descriptor(for: id)?.focuses ?? false).nested(in: ActionRunScope.current)
        for observer in willRunObservers { observer(id, run.origin) }
        // The run's timing has read the press; the handler gets none, so an action it performs
        // later with this invocation does not report this press's age.
        var handed = invocation
        handed.inputTimestamp = nil
        // The effect is settled inside the run's scopes, so the remote half it starts keeps the run's
        // view-change permission and machine routing.
        ActionRunScope.$current.withValueInTask(run) {
            if let invocationScope {
                invocationScope(handed) { settle(action.run(handed), of: id, handed) }
            } else {
                settle(action.run(handed), of: id, handed)
            }
        }
        runObserver?(id, handed)
    }
}
