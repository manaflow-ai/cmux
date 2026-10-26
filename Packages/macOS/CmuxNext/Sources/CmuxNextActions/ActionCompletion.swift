public import CmuxNextWakeups

/// Task locals of an action run that live outside this package (the App's daemon command scope), bound
/// again in work the run posts or starts. A posted main-thread task runs from a run loop turn or a frame,
/// outside the run's task tree, so it inherits none of them.
public nonisolated protocol ActionRunLocals: Sendable {
    /// Runs `body` with these locals bound, inside a task (`TaskLocal.withValueInTask`).
    @MainActor func bind<T>(_ body: () -> T) -> T
    /// Runs async `body` with these locals bound, in the task that awaits it.
    nonisolated func bindAwaiting<T>(_ body: () async -> T) async -> T
}

/// The main-thread end of one action run, taken in the run's own turn (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// rule 2: "Async completions are userBlocking"). It carries what that end must keep when it runs as a posted task,
/// outside the run's task tree:
///
/// - its class: ``BudgetedWorkClass/userBlocking`` for a person's run (the rest of their action, Chrome
///   kUserBlocking in content/browser/scheduler/browser_task_queues.h), ``BudgetedWorkClass/automation`` for any
///   other, so an agent's or the CLI's completion yields to the person's input;
/// - its cause in ``MainWorkScheduler/causes`` (``ActionOrigin/observationCause``);
/// - the person's input it answers (``MainFrameBudget/answerableInput``), whose response its commit closes;
/// - the run's ``ActionRunScope`` (a CLI run without `focus` must not change the view from its completion) and the
///   App's ``ActionRunLocals`` (the daemon command scope: the CLI's `action.run` waits for the tickets of commands a
///   completion sends, and their derived idempotency keys).
///
/// ```swift
/// let completion = registry.completion(on: services.mainWork)
/// completion.start {
///     let asked = await DestructiveConfirmation.runningPrograms(bySurface: terminals, on: daemon)
///     completion.post(owner: "TabCloseGuard.close", answering: true) { close(asked) }
/// }
/// ```
public nonisolated struct ActionCompletion: Sendable {
    /// The class every task of this end runs in.
    public let workClass: BudgetedWorkClass
    let cause: ObservationCause
    let answers: MainFrameBudget.InputToken?
    let scope: ActionRunScope?
    let locals: (any ActionRunLocals)?
    let mainWork: MainWorkScheduler

    /// The end of the run current on this task (``ActionRunScope/current``; outside a run, a direct gesture of this
    /// client's person), on `mainWork`. Take it in the run's turn: the input it answers is the one dispatching now.
    @MainActor
    public init(on mainWork: MainWorkScheduler, locals: (any ActionRunLocals)? = nil) {
        let run = ActionRunScope.current
        let cause = (run?.origin ?? .user).observationCause
        self.workClass = cause == .person ? .userBlocking : .automation
        self.cause = cause
        self.answers = cause == .person ? mainWork.budget.answerableInput : nil
        self.scope = run
        self.locals = locals
        self.mainWork = mainWork
    }

    /// The task priority of off-main work this run waits for: `userBlocking` for a person's run, else `userVisible`.
    public var priority: WorkPriority { cause == .person ? .userBlocking : .userVisible }

    /// Runs `body` on the main thread as one task of ``workClass`` named `owner`, with the run's scopes and cause
    /// bound, and returns what it returns. `answering`: this is the run's last step, whose commit answers the
    /// person's input.
    public func apply<T: Sendable>(owner: String, answering: Bool = false, file: StaticString = #fileID, line: UInt = #line,
                                   _ body: @escaping @MainActor @Sendable () -> T) async -> T {
        await mainWork.apply(workClass, owner: owner, file: file, line: line) { self.run(answering: answering, body) }
    }

    /// Queues `body` from any thread as one task of ``workClass`` named `owner`, with the run's scopes and cause
    /// bound (``apply(owner:answering:file:line:_:)`` without the wait).
    public func post(owner: String, answering: Bool = false, file: StaticString = #fileID, line: UInt = #line,
                     _ body: @escaping @MainActor @Sendable () -> Void) {
        mainWork.postFromAnyThread(workClass, owner: owner, file: file, line: line) { self.run(answering: answering, body) }
    }

    /// Starts `work` off the main thread at ``priority`` with the run's scopes bound. Unlike a detached
    /// `BackgroundWork.task`, the daemon commands it sends keep the run's command scope and view permission.
    @discardableResult
    public func start<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> Task<T, Never> {
        let scope = scope, locals = locals
        return Task(priority: priority.taskPriority) {
            await ActionRunScope.$current.withValueAwaiting(scope) { () async -> T in
                guard let locals else { return await work() }
                return await locals.bindAwaiting { await work() }
            }
        }
    }

    /// Runs `body` here, on the main thread, with the run's scopes and cause bound (the inside of a posted task).
    @MainActor
    public func run<T>(answering: Bool = false, _ body: () -> T) -> T {
        let result = ActionRunScope.carrying(scope) {
            mainWork.causes.withCause(cause) { () -> T in
                guard let locals else { return body() }
                return locals.bind(body)
            }
        }
        if answering, let answers { mainWork.budget.noteAnswered(answers) }
        return result
    }
}

extension ActionRegistry {
    /// The main-thread end of the run current on this task, with the App's run locals (``runLocals``). Take it in
    /// the handler's turn, before any `await`.
    public func completion(on mainWork: MainWorkScheduler) -> ActionCompletion {
        ActionCompletion(on: mainWork, locals: runLocals?())
    }
}
