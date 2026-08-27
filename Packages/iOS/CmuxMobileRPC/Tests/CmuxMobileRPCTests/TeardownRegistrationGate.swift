import Foundation

actor TeardownRegistrationGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let waitingForEntry = entryWaiters
        entryWaiters.removeAll()
        for waiter in waitingForEntry { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation {
            releaseWaiters.append($0)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation {
            entryWaiters.append($0)
        }
    }

    func release() {
        released = true
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waitingForRelease { waiter.resume() }
    }
}
