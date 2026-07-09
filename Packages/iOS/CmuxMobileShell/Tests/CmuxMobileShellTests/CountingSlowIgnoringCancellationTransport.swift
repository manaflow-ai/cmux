import CMUXMobileCore
import CmuxMobileRPC
import Foundation

actor CountingSlowIgnoringCancellationTransport: CmxByteTransport {
    private var connects = 0
    private var isFinished = false
    private var connectWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    func connect() async throws {
        connects += 1
        connectWaiters.forEach { $0.resume() }
        connectWaiters.removeAll()
        guard !isFinished else {
            throw MobileShellConnectionError.requestTimedOut
        }
        await withCheckedContinuation { continuation in
            finishWaiters.append(continuation)
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

    func waitForConnect() async {
        guard connects == 0 else { return }
        await withCheckedContinuation { continuation in
            connectWaiters.append(continuation)
        }
    }

    func finishConnects() {
        isFinished = true
        finishWaiters.forEach { $0.resume() }
        finishWaiters.removeAll()
    }
}
