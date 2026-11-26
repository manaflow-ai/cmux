import CMUXMobileCore
import CmuxMobileRPC
import Foundation

actor CountingSlowIgnoringCancellationTransport: CmxByteTransport {
    private var connects = 0
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func connect() async throws {
        connects += 1
        await waitUntilReleased()
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

    func releaseStuckConnects() {
        isReleased = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func waitUntilReleased() async {
        if isReleased { return }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }
}
