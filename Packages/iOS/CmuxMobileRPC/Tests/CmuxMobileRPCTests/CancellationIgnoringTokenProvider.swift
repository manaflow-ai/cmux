import Foundation

actor CancellationIgnoringTokenProvider {
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var didRelease = false
    private(set) var startCount = 0

    func token() async throws -> String {
        startCount += 1
        while !didRelease {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return "released-token"
    }

    func waitUntilStartCount(_ expected: Int) async {
        for _ in 0..<200 {
            if startCount >= expected { return }
            await Task.yield()
        }
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
