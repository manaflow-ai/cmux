/// Waits on the main actor, with no task, for `read` to give a value, `limit` at most: a
/// ``ServiceObservation`` of `read` raced against a ``MainDeadline``, both in one class (Chrome's
/// posted task with a `TaskPriority` and a `OneShotTimer` on the same task runner,
/// base/task/task_traits.h, base/timer/timer.h). The first to end stops both and calls `then`
/// once, with the value, or nil at the limit.
///
/// A value already there calls `then` before ``start(_:owner:within:work:deadlines:file:line:read:then:)``
/// returns. While it waits, its deadline's action holds it, so a caller need not keep the returned
/// wait. A caller that changes the view in `then` binds its action run's scope there itself
/// (`ActionRunScope.carrying`): this type runs `then` from a posted task, where no task local is bound.
///
/// ```swift
/// FirstValueWait.start(.userBlocking, owner: "Reveal.mount", within: .seconds(10), work: work, deadlines: deadlines) {
///     panes.controller(for: pane)
/// } then: { controller in
///     controller?.select(surface)
/// }
/// ```
@MainActor
public final class FirstValueWait<Value> {
    /// The observation of `read`; nil once the wait ended.
    public private(set) var observation: ServiceObservation<Value?>?
    private let limit: MainDeadline
    private var then: (@MainActor (Value?) -> Void)?

    /// Neither a value nor the limit came yet.
    public var isWaiting: Bool { then != nil }

    private init(limit: MainDeadline, then: @escaping @MainActor (Value?) -> Void) {
        self.limit = limit
        self.then = then
    }

    // Generic main-actor class: an isolated deinit crashes the Release optimizer (#23050).
    nonisolated deinit {}

    /// Starts the wait.
    ///
    /// - Parameters:
    ///   - workClass: The class of the flush and of the limit's action: `userBlocking` when a
    ///     person waits on it, `automation` when an agent or the CLI does.
    ///   - owner: The name the board, the ledger and the signposts show.
    ///   - limit: The longest wait; `then` gets nil after it.
    ///   - work: The app's one main-thread scheduler.
    ///   - deadlines: The app's one deadline scheduler.
    ///   - file: The limit's posting file (leave the default).
    ///   - line: The limit's posting line (leave the default).
    ///   - read: The observed expression; nil while the value has not come.
    ///   - then: Runs once, with the value or nil at the limit.
    @discardableResult
    public static func start(_ workClass: BudgetedWorkClass, owner: String, within limit: Duration,
                             work: MainWorkScheduler, deadlines: MainDeadlineScheduler,
                             file: StaticString = #fileID, line: UInt = #line,
                             read: @escaping @MainActor () -> Value?,
                             then: @escaping @MainActor (Value?) -> Void) -> FirstValueWait<Value> {
        let deadline = MainDeadline(owner: owner, workClass: workClass, scheduler: deadlines, file: file, line: line)
        let wait = FirstValueWait(limit: deadline, then: then)
        let observation = ServiceObservation(workClass, owner: owner, on: work, read: read) { [weak wait] value in
            if let value { wait?.finish(value) }
        }
        guard wait.isWaiting else {
            observation.cancel()
            return wait
        }
        wait.observation = observation
        deadline.schedule(after: limit) { wait.finish(nil) }
        return wait
    }

    /// Ends the wait without calling `then`. Idempotent.
    public func cancel() {
        then = nil
        stop()
    }

    private func finish(_ value: Value?) {
        guard let then else { return }
        self.then = nil
        stop()
        then(value)
    }

    private func stop() {
        observation?.cancel()
        observation = nil
        limit.cancel()
    }
}
