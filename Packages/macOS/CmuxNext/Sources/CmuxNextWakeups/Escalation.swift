import CmuxNextCompat

/// The priority escalations of one ``BackgroundWork/run(_:mayBlock:shutdown:_:)`` call, before and after
/// its item is submitted.
///
/// An escalation before the submit raises the level the item is queued at; one after it boosts the item
/// in its lane. Both go through one lock with the submit, so no escalation is lost between the two and
/// none is kept for an item that has already been submitted or has finished.
final class Escalation: Sendable {
    private struct State {
        var submitted = false
        var raised: WorkPriority?
    }

    // concurrency-allow: a submitted flag and one priority, taken by the run and its escalation handler (lock carve-out: no I/O under it; the lane's own lock nests inside, always in this order).
    private let state = Mutex(State())

    /// Submits at `priority`, raised by any escalation that came first, through `submit`.
    func submit(at priority: WorkPriority, _ submit: (WorkPriority) -> Void) {
        state.withLock { state in
            state.submitted = true
            submit(max(priority, state.raised ?? priority))
        }
    }

    /// Records `priority` until the submit, or boosts the submitted item through `boost`.
    func raise(to priority: WorkPriority, _ boost: (WorkPriority) -> Void) {
        state.withLock { state in
            if state.submitted { return boost(priority) }
            state.raised = max(priority, state.raised ?? priority)
        }
    }
}
