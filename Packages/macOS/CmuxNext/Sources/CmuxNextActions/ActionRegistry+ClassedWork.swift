public import CmuxNextWakeups

// An action's asynchronous part off the main thread, its main-thread end as one task with a class and an
// owner (plans/cmux-next/chrome-parity/p06-scheduler.md, recipe R-hop: "a nonisolated Task for the async part
// plus a reply or apply for the main part"). Chromium posts the reply of off-thread work back to the UI thread
// as a task of its own with a task type (`base::ThreadPool::PostTaskAndReplyWithResult`,
// content/browser/scheduler/browser_task_queues.h), never as an unclassed continuation.
extension ActionRegistry {
    /// Starts `work` off the main thread, then runs `finish` with its result on the main thread as `owner`, and
    /// reports the task to a capturing caller (``track(_:)``) unless `tracked` is false: the CLI's `action.run`
    /// answers with the failure `finish` returns.
    ///
    /// Both halves keep the run of the calling turn (``ActionCompletion``): `finish` is one
    /// ``BudgetedWorkClass/userBlocking`` task for a person's run and answers their input, an
    /// ``BudgetedWorkClass/automation`` task for any other; both see the run's ``ActionRunScope`` and the App's
    /// run locals (the daemon command scope).
    ///
    /// ```swift
    /// registry.trackWork(owner: "RoomHandlers.create", on: services.mainWork) {
    ///     try await connection.createProfile(name: name, id: id)
    /// } then: { result in
    ///     guard case .failure(let error) = result else { return nil }
    ///     return ActionWorkFailure("space.new", error)
    /// }
    /// ```
    ///
    /// A step on the main thread in the middle of `work` is an ``ActionCompletion/apply(owner:answering:file:line:_:)``
    /// of a ``completion(on:)`` taken in the same turn.
    ///
    /// - Parameters:
    ///   - owner: `finish`'s owner on the scheduler's board.
    ///   - mainWork: The app's one main-thread scheduler.
    ///   - tracked: False for work a capturing caller does not wait for (a move into a new window).
    ///   - file: The posting file of `finish` on the board (leave the default).
    ///   - line: The posting line (leave the default).
    ///   - work: The asynchronous part. It runs on the cooperative pool; main-actor calls in it are awaited.
    ///   - finish: The main-thread part: shows the result and returns the run's failure, or nil.
    /// - Returns: The task, already reported.
    @discardableResult
    public func trackWork<Value: Sendable>(owner: String, on mainWork: MainWorkScheduler, tracked: Bool = true,
                                           file: StaticString = #fileID, line: UInt = #line,
                                           _ work: @escaping @Sendable () async throws -> Value,
                                           then finish: @escaping @MainActor @Sendable (Result<Value, any Error>) -> ActionWorkFailure?)
        -> ActionWork {
        let end = self.completion(on: mainWork)
        let task: ActionWork = end.start {
            let result = await Self.result(of: work)
            return await end.apply(owner: owner, answering: true, file: file, line: line) { finish(result) }
        }
        if tracked { track(task) }
        return task
    }

    /// ``trackWork(owner:on:tracked:file:line:_:then:)`` for an action that answers with a value (a created
    /// workspace's fields): `finish` makes the answer on main, and a capturing caller gets it (``track(result:)``).
    ///
    /// - Parameters:
    ///   - owner: `finish`'s owner on the scheduler's board.
    ///   - mainWork: The app's one main-thread scheduler.
    ///   - file: The posting file of `finish` on the board (leave the default).
    ///   - line: The posting line (leave the default).
    ///   - work: The asynchronous part, off main.
    ///   - finish: The main-thread part: the run's answer or failure.
    public func trackResultWork<Value: Sendable>(
        owner: String, on mainWork: MainWorkScheduler, file: StaticString = #fileID, line: UInt = #line,
        _ work: @escaping @Sendable () async throws -> Value,
        then finish: @escaping @MainActor @Sendable (Result<Value, any Error>) -> Result<[String: ActionResultValue], ActionWorkFailure>
    ) {
        let end = self.completion(on: mainWork)
        track(result: end.start {
            let result = await Self.result(of: work)
            return await end.apply(owner: owner, answering: true, file: file, line: line) { finish(result) }
        })
    }

    /// `work`'s value or its error, off main.
    private nonisolated static func result<Value: Sendable>(of work: @Sendable () async throws -> Value) async -> Result<Value, any Error> {
        do {
            return .success(try await work())
        } catch {
            return .failure(error)
        }
    }
}

extension ActionInvocation {
    /// The class of the main-thread work this run's asynchronous part ends with: `userBlocking` for a person's run
    /// in this app (the rest of their action, p06-scheduler.md rule 2), `automation` for a run an agent, the CLI, a
    /// script, a page or another client started, so their completions yield to the person's input.
    public nonisolated var completionClass: BudgetedWorkClass { origin == .user ? .userBlocking : .automation }

    /// The priority of this run's off-main work: `userBlocking` for a person's run in this app (they wait for
    /// it), `userVisible` for any other.
    public nonisolated var completionPriority: WorkPriority { origin == .user ? .userBlocking : .userVisible }
}
