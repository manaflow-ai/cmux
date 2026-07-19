import Foundation

actor ScopedRPCValidationGate {
    private let blockedCall: Int
    private var callCount = 0
    private var isValid = true
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(blockedCall: Int) {
        self.blockedCall = blockedCall
    }

    func validate() async -> Bool {
        callCount += 1
        if callCount == blockedCall {
            let waiters = blockedWaiters
            blockedWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return isValid
    }

    func waitUntilBlocked() async {
        if callCount >= blockedCall { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func invalidateAndRelease() {
        isValid = false
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
