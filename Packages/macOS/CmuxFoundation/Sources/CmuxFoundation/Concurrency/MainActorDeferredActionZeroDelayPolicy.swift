/// Defines how a zero-delay deferred action reaches the main actor.
public enum MainActorDeferredActionZeroDelayPolicy: Sendable, Equatable {
    /// Enqueues the action for the next available main-actor execution.
    case enqueue

    /// Yields one additional actor turn before attempting the action.
    case yieldOnce
}
