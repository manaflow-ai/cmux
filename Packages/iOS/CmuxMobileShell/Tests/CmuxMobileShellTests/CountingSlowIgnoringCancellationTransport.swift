import CMUXMobileCore
import CmuxMobileRPC
import Foundation

actor CountingSlowIgnoringCancellationTransport: CmxByteTransport {
    private var connects = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func connect() async throws {
        connects += 1
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

    func releaseConnects() {
        let continuations = waiters
        waiters = []
        for continuation in continuations {
            continuation.resume()
        }
    }
}
