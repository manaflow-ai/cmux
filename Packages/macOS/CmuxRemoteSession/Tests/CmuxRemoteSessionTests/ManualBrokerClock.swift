import CmuxRemoteWorkspace
@testable import CmuxRemoteSession

actor ManualBrokerClock: RemoteProxyRetryClock {
    private var requestedDelayWaiters: [CheckedContinuation<Int, Never>] = []
    private var unconsumedDelays: [Int] = []
    private var pendingSleeps: [CheckedContinuation<Void, any Error>] = []

    func sleep(forMilliseconds milliseconds: Int) async throws {
        if let waiter = requestedDelayWaiters.first {
            requestedDelayWaiters.removeFirst()
            waiter.resume(returning: milliseconds)
        } else {
            unconsumedDelays.append(milliseconds)
        }
        try await withCheckedThrowingContinuation { continuation in
            pendingSleeps.append(continuation)
        }
    }

    func nextRequestedDelay() async -> Int {
        if !unconsumedDelays.isEmpty {
            return unconsumedDelays.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            requestedDelayWaiters.append(continuation)
        }
    }

    func resumeNextSleep() {
        guard !pendingSleeps.isEmpty else { return }
        pendingSleeps.removeFirst().resume()
    }
}
