import Foundation

actor FirstCallHangsTokenProvider {
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var didRelease = false
    private(set) var startCount = 0

    func token() async throws -> String {
        startCount += 1
        if startCount > 1 {
            return "second-token"
        }
        while !didRelease {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return "released-token"
    }

    func release() {
        didRelease = true
        let waiters = releaseWaiters
        releaseWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
