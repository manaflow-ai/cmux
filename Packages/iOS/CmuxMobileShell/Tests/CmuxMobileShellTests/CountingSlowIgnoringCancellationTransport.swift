import CMUXMobileCore
import CmuxMobileRPC
import Foundation

actor CountingSlowIgnoringCancellationTransport: CmxByteTransport {
    private var connects = 0
    private var connectCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func connect() async throws {
        connects += 1
        resumeConnectCountWaiters()
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        throw MobileShellConnectionError.requestTimedOut
    }

    func receive() async throws -> Data? {
        nil
    }

    func send(_ data: Data) async throws {}

    func close() async {}

    func connectCount() -> Int {
        connects
    }

    func waitForConnectCount(_ count: Int) async {
        guard connects < count else { return }
        await withCheckedContinuation { continuation in
            connectCountWaiters.append((count, continuation))
        }
    }

    func releaseConnects() {
        let continuations = waiters
        waiters = []
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func resumeConnectCountWaiters() {
        let ready = connectCountWaiters.filter { connects >= $0.count }
        connectCountWaiters.removeAll { connects >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}
