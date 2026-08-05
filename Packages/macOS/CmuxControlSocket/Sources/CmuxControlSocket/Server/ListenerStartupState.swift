/// The authoritative listener-start lifecycle.
///
/// Generation checks make delayed wakes harmless after stop or an explicit
/// restart. The waiting case owns the request and failure count, so the timer
/// task carries no lifecycle state and can only request a wakeup.
enum ListenerStartupState: Equatable, Sendable {
    /// No startup operation is active. A listener may already be running.
    case idle(generation: UInt64)
    /// One synchronous startup attempt owns the request on the main actor.
    case starting(generation: UInt64, request: ListenerStartRequest, failureCount: Int)
    /// A bounded delay is pending before the same request may retry.
    case waiting(generation: UInt64, request: ListenerStartRequest, failureCount: Int)

    var generation: UInt64 {
        switch self {
        case .idle(let generation),
             .starting(let generation, _, _),
             .waiting(let generation, _, _):
            return generation
        }
    }

    var isStarting: Bool {
        if case .starting = self { return true }
        return false
    }

    var isWaiting: Bool {
        if case .waiting = self { return true }
        return false
    }
}
