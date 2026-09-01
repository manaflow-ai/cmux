import CmuxFoundation

/// Serializes the irreversible loginwindow call with Sleepy Mode cancellation.
///
/// One atomic pending token is the linearization point: invocation and
/// cancellation both try to claim the same transition. If cancellation wins, no
/// lock is issued; if invocation wins, the request began before lifecycle
/// teardown and is allowed to finish.
final class SleepyLockInvocationGate: @unchecked Sendable {
    // Safety: this immutable reference owns the only mutable request state, and
    // every transition uses AtomicBooleanGate's compare-and-exchange operation.
    private let isPending = AtomicBooleanGate(true)

    /// Invokes an irreversible action only while this request is live.
    @discardableResult
    func invoke(_ action: @Sendable () -> Void) -> Bool {
        guard isPending.compareExchange(expected: true, desired: false) else {
            return false
        }
        action()
        return true
    }

    /// Revokes this request before it can invoke its action.
    @discardableResult
    func cancel() -> Bool {
        isPending.compareExchange(expected: true, desired: false)
    }
}
