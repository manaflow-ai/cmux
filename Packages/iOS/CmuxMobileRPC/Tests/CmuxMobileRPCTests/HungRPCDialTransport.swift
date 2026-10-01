import CMUXMobileCore
import Foundation

/// Keeps native connect suspended even after close; only the test can release it.
actor HungRPCDialTransport: CmxByteTransport {
    private var connectContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var closes = 0

    func connect() async throws {
        await withCheckedContinuation { continuation in
            connectContinuation = continuation
            let waiting = startWaiters
            startWaiters = []
            waiting.forEach { $0.resume() }
        }
    }
    func receive() async throws -> Data? { nil }
    func send(_ data: Data) async throws {}
    func close() async {
        closes += 1
        if closes >= 2 {
            let waiting = closeWaiters
            closeWaiters = []
            waiting.forEach { $0.resume() }
        }
    }
    func waitUntilStarted() async {
        if connectContinuation != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release() {
        connectContinuation?.resume()
        connectContinuation = nil
    }
    func waitUntilLateCandidateClosed() async {
        if closes >= 2 { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }
}
