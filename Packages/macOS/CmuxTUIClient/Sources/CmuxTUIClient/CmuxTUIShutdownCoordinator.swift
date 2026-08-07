/// Makes one asynchronous shutdown operation idempotent while preserving its completion barrier.
@MainActor
public final class CmuxTUIShutdownCoordinator {
    private var isRunning = false
    private var didFinish = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func run(_ operation: @MainActor () async -> Void) async {
        if didFinish { return }
        if isRunning {
            await withCheckedContinuation { continuation in
                if didFinish {
                    continuation.resume()
                } else {
                    self.waiters.append(continuation)
                }
            }
            return
        }

        isRunning = true
        await operation()
        didFinish = true
        isRunning = false
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }
}
