import Foundation

actor SimulatorFrameTransportPublicationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var attemptCompleted = false

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilBlocked() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if continuation != nil { return }
            try await clock.sleep(for: .milliseconds(1))
        }
        throw CancellationError()
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func completeAttempt() {
        attemptCompleted = true
    }

    func waitUntilAttemptCompleted() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if attemptCompleted { return }
            try await clock.sleep(for: .milliseconds(1))
        }
        throw CancellationError()
    }
}
