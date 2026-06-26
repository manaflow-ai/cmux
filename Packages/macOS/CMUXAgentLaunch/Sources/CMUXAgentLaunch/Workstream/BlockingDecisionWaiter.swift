import Foundation

/// A parked blocking-decision waiter. Owns the semaphore the socket worker
/// blocks on while a `feed.push` hook waits for a user decision, a slot for the
/// resolved decision, and the attention overlay target surfaced for the
/// decision.
///
/// All mutable state is read and written only under
/// ``BlockingDecisionWaiterRegistry``'s lock, except after the waiter has been
/// removed from the registry, at which point it is owned solely by the remover.
/// `@unchecked Sendable` because that locking discipline, not the type system,
/// guarantees data-race freedom.
public final class BlockingDecisionWaiter: @unchecked Sendable {
    let semaphore: DispatchSemaphore
    var decision: WorkstreamDecision?
    /// The attention overlay target for this decision, if one was surfaced.
    /// Set inside the ingest `main.sync` (before the card can render and a
    /// reply can fire) and read when the decision concludes, so the
    /// needs-input overlay is cleared exactly once.
    var attentionTarget: AttentionTarget?

    init(semaphore: DispatchSemaphore) {
        self.semaphore = semaphore
    }

    /// The resolved decision, once a reply has been delivered. `nil` while the
    /// waiter is still awaiting input.
    public var resolvedDecision: WorkstreamDecision? { decision }

    /// The attention overlay target recorded for this decision, if any.
    public var resolvedAttentionTarget: AttentionTarget? { attentionTarget }
}
