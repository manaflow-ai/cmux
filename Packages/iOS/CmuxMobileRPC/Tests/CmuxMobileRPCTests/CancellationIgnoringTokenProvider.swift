import Foundation

actor CancellationIgnoringTokenProvider {
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var didRelease = false
    private(set) var startCount = 0

    func token() async throws -> String {
        startCount += 1
        let started = startWaiters.filter { $0.count <= startCount }
        startWaiters.removeAll { $0.count <= startCount }
        started.forEach { $0.continuation.resume() }
        while !didRelease {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return "released-token"
    }

    func waitUntilStartCount(_ expected: Int) async {
        if startCount >= expected { return }
        await withCheckedContinuation { startWaiters.append((expected, $0)) }
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
