import Foundation

actor AgentCommandShimInstallProbe {
    private var installationCount = 0
    private var countWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func install() async {
        installationCount += 1
        let ready = countWaiters.filter { installationCount >= $0.target }
        countWaiters.removeAll { installationCount >= $0.target }
        for waiter in ready {
            waiter.continuation.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitForInstallationCount(_ target: Int) async {
        guard installationCount < target else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((target, continuation))
        }
    }

    func count() -> Int {
        installationCount
    }

    func releaseAll() {
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}
