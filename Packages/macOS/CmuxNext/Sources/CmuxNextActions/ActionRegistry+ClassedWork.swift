public import CmuxNextWakeups

// An action's asynchronous part off the main thread, its main-thread end as one task with a class and an
// owner (plans/cmux-next/chrome-parity/p06-scheduler.md, recipe R-hop: "a nonisolated Task for the async part
// plus a reply or apply for the main part"). Chromium posts the reply of off-thread work back to the UI thread
// as a task of its own with a task type (`base::ThreadPool::PostTaskAndReplyWithResult`,
// content/browser/scheduler/browser_task_queues.h), never as an unclassed continuation.
extension ActionRegistry {
    /// Starts `work` off the main thread, then runs `finish` with its result on the main thread in
    /// `workClass` as `owner`, and reports the task to a capturing caller (``track(_:)``) unless `tracked`
    /// is false: the CLI's `action.run` answers with the failure `finish` returns.
    ///
    /// ```swift
    /// registry.trackWork(invocation.completionClass, owner: "RoomHandlers.create", on: services.mainWork) {
    ///     try await connection.createProfile(name: name, id: id)
    /// } then: { result in
    ///     guard case .failure(let error) = result else { return nil }
    ///     return ActionWorkFailure("space.new", error)
    /// }
    /// ```
    ///
    /// A step on the main thread in the middle of `work` is a `mainWork.apply(_:owner:_:)` of its own.
    ///
    /// - Parameters:
    ///   - workClass: The class of `finish`: ``ActionInvocation/completionClass`` for the run's own result.
    ///   - owner: `finish`'s owner on the scheduler's board.
    ///   - mainWork: The app's one main-thread scheduler.
    ///   - tracked: False for work a capturing caller does not wait for (a move into a new window).
    ///   - file: The posting file of `finish` on the board (leave the default).
    ///   - line: The posting line (leave the default).
    ///   - work: The asynchronous part. It runs on the cooperative pool; main-actor calls in it are awaited.
    ///   - finish: The main-thread part: shows the result and returns the run's failure, or nil.
    /// - Returns: The task, already reported.
    @discardableResult
    public func trackWork<Value: Sendable>(_ workClass: BudgetedWorkClass, owner: String, on mainWork: MainWorkScheduler,
                                           tracked: Bool = true, file: StaticString = #fileID, line: UInt = #line,
                                           _ work: @escaping @Sendable () async throws -> Value,
                                           then finish: @escaping @MainActor @Sendable (Result<Value, any Error>) -> ActionWorkFailure?)
        -> ActionWork {
        let task: ActionWork = Self.offMain(work) { result in
            await mainWork.apply(workClass, owner: owner, file: file, line: line) { finish(result) }
        }
        if tracked { track(task) }
        return task
    }

    /// ``trackWork(_:owner:on:tracked:file:line:_:then:)`` for an action that answers with a value (a created
    /// workspace's fields): `finish` makes the answer on main, and a capturing caller gets it (``track(result:)``).
    ///
    /// - Parameters:
    ///   - workClass: The class of `finish`.
    ///   - owner: `finish`'s owner on the scheduler's board.
    ///   - mainWork: The app's one main-thread scheduler.
    ///   - file: The posting file of `finish` on the board (leave the default).
    ///   - line: The posting line (leave the default).
    ///   - work: The asynchronous part, off main.
    ///   - finish: The main-thread part: the run's answer or failure.
    public func trackResultWork<Value: Sendable>(
        _ workClass: BudgetedWorkClass, owner: String, on mainWork: MainWorkScheduler, file: StaticString = #fileID,
        line: UInt = #line, _ work: @escaping @Sendable () async throws -> Value,
        then finish: @escaping @MainActor @Sendable (Result<Value, any Error>) -> Result<[String: ActionResultValue], ActionWorkFailure>
    ) {
        track(result: Self.offMain(work) { result in
            await mainWork.apply(workClass, owner: owner, file: file, line: line) { finish(result) }
        })
    }

    /// A task with no actor to inherit (made in a nonisolated function): `work` runs on the cooperative pool,
    /// then `end` gets its result. Chromium's `PostTaskAndReplyWithResult` sends the reply back as a task of its
    /// own; `end` posts it (``MainWorkScheduler/apply(_:owner:file:line:_:)``).
    private nonisolated static func offMain<Value: Sendable, Answer: Sendable>(
        _ work: @escaping @Sendable () async throws -> Value,
        end: @escaping @Sendable (Result<Value, any Error>) async -> Answer
    ) -> Task<Answer, Never> {
        Task {
            let result: Result<Value, any Error>
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            return await end(result)
        }
    }
}

extension ActionInvocation {
    /// The class of the main-thread work this run's asynchronous part ends with: `visible` for a person's
    /// run in this app, `automation` for a run an agent, the CLI, a script, a page or another client started,
    /// so their completions yield to the person's input (p06-scheduler.md section 4, rule 2).
    public nonisolated var completionClass: BudgetedWorkClass { origin == .user ? .visible : .automation }

    /// The priority of this run's off-main work: `userBlocking` for a person's run in this app (they wait for
    /// it), `userVisible` for any other.
    public nonisolated var completionPriority: WorkPriority { origin == .user ? .userBlocking : .userVisible }
}

extension ActionRunScope {
    /// ``ActionInvocation/completionClass`` of the run on this task (`visible` outside a run), for a helper
    /// that has no invocation at hand.
    public nonisolated static var completionClass: BudgetedWorkClass {
        (current?.origin ?? .user) == .user ? .visible : .automation
    }
}
