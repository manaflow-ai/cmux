internal import CMUXMobileCore
internal import class CmuxSafeConcurrency.OnceContinuation
internal import enum CmuxSafeConcurrency.OnceContinuationError
internal import func CmuxSafeConcurrency.withOnceContinuation

/// Captures the physical close started by a connect task's cancellation
/// handler. The abandoned-connect cleaner combines this task with any late
/// candidate close under one route lease.
actor MobileRPCConnectCancellationClose {
    private var closeTask: Task<Void, Never>?
    private var settledWithoutClose = false
    private var startWaiters: [
        OnceContinuation<Task<Void, Never>?, OnceContinuationError>
    ] = []

    func start(_ candidate: any CmxByteTransport) {
        guard closeTask == nil, !settledWithoutClose else { return }
        let task = Task.detached {
            await candidate.close()
        }
        closeTask = task
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters {
            waiter.resume(returning: task)
        }
    }

    func finishWithoutClose() {
        guard closeTask == nil, !settledWithoutClose else { return }
        settledWithoutClose = true
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    func task() async -> Task<Void, Never>? {
        if let closeTask {
            return closeTask
        }
        if settledWithoutClose {
            return nil
        }
        // A dropped waiter reads as settled without a close.
        return try? await withOnceContinuation { (waiter: OnceContinuation<Task<Void, Never>?, OnceContinuationError>) in
            startWaiters.append(waiter)
        }
    }
}
