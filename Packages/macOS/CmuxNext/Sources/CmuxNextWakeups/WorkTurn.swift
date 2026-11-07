/// A place in a line of work, taken now and filled later: the work handed to ``fill(_:)`` can await ``earlier``, the place
/// before it, and the next place awaits ``place``, which ends with that work. A place not filled within `limit` passes its
/// turn. `NewTabSlot` takes one per new tab at the press, so a pane's new tabs move in the order they were asked for,
/// whichever answer comes first.
public struct WorkTurn<Result: Sendable>: Sendable {
    /// The place before this one (nil: the first).
    public let earlier: Task<Result, Never>?
    /// This place: ends after `earlier` and the work filled in (`passing` when none came within the limit).
    public let place: Task<Result, Never>
    private let answer: FirstOutcome<Task<Result, Never>?>

    public init(after earlier: Task<Result, Never>?, limit: Duration, owner: String, passing: Result) {
        let answer = FirstOutcome<Task<Result, Never>?>(), timer = DemandTimer(owner: owner)
        timer.schedule(after: limit) { answer.resolve(nil) }
        (self.earlier, self.answer) = (earlier, answer)
        // task-owner: the place itself (`place`, awaited by the next); bounded by `limit` and the work filled in
        place = Task {
            _ = await earlier?.value
            let work = await answer.value()
            timer.cancel()
            return await work?.value ?? passing
        }
    }

    /// Hands this place its work (the first call wins; none after the limit passed).
    public func fill(_ work: Task<Result, Never>) { answer.resolve(work) }
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
