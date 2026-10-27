public import CmuxNextWakeups

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
    /// The `NSEvent.timestamp` of the person's key or click this run answers: the event being
    /// dispatched when the run started, else the stamp a gate carried in its invocation
    /// (``ActionInvocation/inputTimestamp``), else the outer run's. Nil for a run no person
    /// started (CLI, socket, script, page, remote). The run's `action.*` row reads the same input;
    /// a switch the run makes in a later turn (after a daemon reply, in a task it started) reads
    /// it here, so its `switch.*` interval answers the same press (`InputDispatchContext.inputTimestamp`).
    public var inputTimestamp: Double?

    public init(origin: ActionOrigin, allowsViewChange: Bool, inputTimestamp: Double? = nil) {
        self.origin = origin
        self.allowsViewChange = allowsViewChange
        self.inputTimestamp = origin == .user ? inputTimestamp : nil
    }

    /// The scope of a run of an action described as `focuses` (or not), answering the person's
    /// input stamped `inputTimestamp` (nil without one).
    public init(_ invocation: ActionInvocation, focuses: Bool, inputTimestamp: Double? = nil) {
        self.init(origin: invocation.origin, allowsViewChange: invocation.allowsViewChange || focuses, inputTimestamp: inputTimestamp)
    }

    /// This scope as a run started inside `outer`: a handler that runs
    /// another action never gains a permission its own run lacks (an inner
    /// run is built with the default user origin), and an inner run without
    /// its own input answers the outer run's.
    public func nested(in outer: ActionRunScope?) -> ActionRunScope {
        guard let outer else { return self }
        return ActionRunScope(origin: outer.origin, allowsViewChange: outer.allowsViewChange && allowsViewChange,
                              inputTimestamp: inputTimestamp ?? outer.inputTimestamp)
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
        // The press the run answers, as its `action.*` row reads it (ActionRegistry+Signposts): kept in the run's
        // scope, which its tasks inherit, so a switch it makes in a later turn answers the same press.
        let press = Self.inputTimestamp(of: dispatchingInputEvent()) ?? invocation.inputTimestamp
        let run = ActionRunScope(invocation, focuses: descriptor(for: id)?.focuses ?? false, inputTimestamp: press)
            .nested(in: ActionRunScope.current)
        for observer in willRunObservers { observer(id, run.origin) }
        // The run's timing has read the press and its scope keeps it; the handler's invocation gets none, so an
        // action it performs later with this invocation does not report this press's age as its own row's.
        var handed = invocation
        handed.inputTimestamp = nil
        // The effect is settled inside the run's scopes, so the remote half it starts keeps the run's
        // view-change permission and machine routing.
        ActionRunScope.$current.withValueInTask(run) {
            run.origin.withCause(in: causes) {
                if let invocationScope {
                    invocationScope(handed) { settle(action.run(handed), of: id, handed) }
                } else {
                    settle(action.run(handed), of: id, handed)
                }
            }
        }
        runObserver?(id, handed)
    }
}

nonisolated extension ActionOrigin {
    /// The scheduling cause of a run this origin started (plans/cmux-next/chrome-parity/p06-scheduler.md
    /// section D: automation never competes with the person): a person in this app is
    /// ``ObservationCause/person``; the CLI, MCP, a script, another client and a page are
    /// ``ObservationCause/automation`` (a page call is the person's only once a native sheet
    /// confirmed it, which raises its origin to `user`). Scheduling only: authorization reads the
    /// origin itself.
    public var observationCause: ObservationCause {
        switch self {
        case .user: .person
        case .cli, .mcp, .script, .remote, .page: .automation
        }
    }

    /// Runs `body` with ``observationCause`` as the current cause in `causes`; with none it only runs `body`.
    @MainActor
    func withCause(in causes: ObservationCauses?, _ body: () -> Void) {
        guard let causes else { return body() }
        causes.withCause(observationCause) { body() }
    }
}
