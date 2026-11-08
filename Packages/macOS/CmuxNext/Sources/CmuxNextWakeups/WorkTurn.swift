import os

private let workTurnLog = Logger(subsystem: "com.cmuxterm.app.next", category: "wakeups")

/// A place in a line of work, taken now and filled later: the work handed to ``fill(_:)`` can await ``earlier``, the place
/// before it, and the next place awaits ``place``, which ends with that work. `NewTabSlot` takes one per new tab at the
/// press, so a pane's new tabs move in the order they were asked for, whichever answer comes first, however late.
///
/// The turn is released by its own outcome: filled on a success; released at once when ``pass()`` is called or when the
/// turn itself is let go unfilled (the reply's callback dropped: the creation failed, was cancelled, or its pane closed).
/// `limit` is only a safety for a reply that never comes; passing there is logged.
public final class WorkTurn<Result: Sendable>: Sendable {
    /// The place before this one (nil: the first).
    public let earlier: Task<Result, Never>?
    /// This place: ends after `earlier` and the work filled in (`passing` when the turn passed with none).
    public let place: Task<Result, Never>
    private let answer: FirstOutcome<Task<Result, Never>?>
    private let owner: String

    public init(after earlier: Task<Result, Never>?, limit: Duration, owner: String, passing: Result) {
        let answer = FirstOutcome<Task<Result, Never>?>(), timer = DemandTimer(owner: owner)
        timer.schedule(after: limit) {
            if answer.resolve(nil) { workTurnLog.notice("\(owner, privacy: .public): no answer within \(String(describing: limit), privacy: .public); its turn passes") }
        }
        (self.earlier, self.answer, self.owner) = (earlier, answer, owner)
        // task-owner: the place itself (`place`, awaited by the next); ends with the work filled in, a release, or `limit`
        place = Task {
            _ = await earlier?.value
            let work = await answer.value()
            timer.cancel()
            return await work?.value ?? passing
        }
    }

    deinit { answer.resolve(nil) } // let go unfilled: the work it waited for will never come

    /// Hands this place its work (the first outcome wins). A fill after the safety limit passed runs unordered, and is logged.
    public func fill(_ work: Task<Result, Never>) {
        if !answer.resolve(work) { workTurnLog.notice("\(self.owner, privacy: .public): answered after its turn passed") }
    }

    /// Releases the turn at once with no work (the reply failed): the next place goes on.
    public func pass() { answer.resolve(nil) }
}

/// A line of ``WorkTurn``s: each ``next(limit:owner:passing:)`` takes the place after the last one taken.
@MainActor
public final class WorkLine<Result: Sendable> {
    private var last: Task<Result, Never>?

    public init() {}

    nonisolated deinit {}

    public func next(limit: Duration, owner: String, passing: Result) -> WorkTurn<Result> {
        let turn = WorkTurn(after: last, limit: limit, owner: owner, passing: passing)
        last = turn.place
        return turn
    }
}
