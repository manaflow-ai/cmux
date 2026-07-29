internal import CMUXMobileCore

/// Captures the physical close started by a connect task's cancellation
/// handler. The abandoned-connect cleaner combines this task with any late
/// candidate close under one route lease.
actor MobileRPCConnectCancellationClose {
    private var closeTask: Task<Void, Never>?
    private var startWaiters: [
        CheckedContinuation<Task<Void, Never>, Never>
    ] = []

    func start(_ candidate: any CmxByteTransport) {
        guard closeTask == nil else { return }
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

    func task(waitForStart: Bool) async -> Task<Void, Never>? {
        if let closeTask {
            return closeTask
        }
        guard waitForStart else {
            return nil
        }
        return await withCheckedContinuation {
            startWaiters.append($0)
        }
    }
}
