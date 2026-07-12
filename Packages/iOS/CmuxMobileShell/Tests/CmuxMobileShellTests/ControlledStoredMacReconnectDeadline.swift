import Foundation

actor ControlledStoredMacReconnectDeadline {
    private var isArmed = false
    private var armWaiters: [CheckedContinuation<Void, Never>] = []
    private var deadlineWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
        isArmed = true
        let waiters = armWaiters
        armWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            deadlineWaiter = continuation
        }
    }

    func waitUntilArmed() async {
        if isArmed { return }
        await withCheckedContinuation { continuation in
            armWaiters.append(continuation)
        }
    }

    func expire() async {
        deadlineWaiter?.resume()
        deadlineWaiter = nil
        await Task.yield()
        await Task.yield()
    }
}
