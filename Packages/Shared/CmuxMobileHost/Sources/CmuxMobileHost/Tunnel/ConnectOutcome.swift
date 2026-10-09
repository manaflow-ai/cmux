/// Settles one connect exactly once: the state handler, the deadline and
/// cancellation race; later calls are no-ops.
actor ConnectOutcome {
    private var waiter: CheckedContinuation<Result<Void, MobileLoopbackConnectError>, Never>?
    private var result: Result<Void, MobileLoopbackConnectError>?

    func wait() async -> Result<Void, MobileLoopbackConnectError> {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }

    func finish(_ outcome: Result<Void, MobileLoopbackConnectError>) {
        guard result == nil else { return }
        result = outcome
        waiter?.resume(returning: outcome)
        waiter = nil
    }
}
