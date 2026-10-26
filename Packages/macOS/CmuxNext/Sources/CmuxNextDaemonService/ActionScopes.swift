public import CmuxNextActions
public import CmuxNextDaemon

/// The action scopes of the code running now: the run's daemon commands (``DaemonCommandScope``: its
/// tickets, idempotent ids and the person cause of its echoes) and its view-change permission
/// (``ActionRunScope``). A `BackgroundWork.task` is detached and inherits no task local, and a step it
/// posts to the main thread runs outside any task tree, so a run's work that hops there carries these
/// and binds them again: `action.run` still waits for its commands, a retry still replays them.
public nonisolated struct ActionScopes: Sendable {
    public let command: DaemonCommandScope?
    public let run: ActionRunScope?

    public init(command: DaemonCommandScope?, run: ActionRunScope?) {
        self.command = command
        self.run = run
    }

    /// The scopes bound where this is read.
    public static var current: ActionScopes {
        ActionScopes(command: DaemonCommandScope.current, run: ActionRunScope.current)
    }

    /// Runs async `body` with the scopes bound, in the task that awaits it.
    public func awaiting<T>(_ body: () async -> T) async -> T {
        await DaemonCommandScope.$current.withValueAwaiting(command) {
            await ActionRunScope.$current.withValueAwaiting(run) { await body() }
        }
    }

    /// Runs main-actor `body` with the scopes bound (a step posted to the main thread).
    @MainActor
    public func applying<T>(_ body: () -> T) -> T {
        DaemonCommandScope.$current.withValueInTask(command) {
            ActionRunScope.$current.withValueInTask(run, operation: body)
        }
    }
}
