import CMUXMobileCore
import CmuxMobileRPC
import Foundation

actor CountingSlowIgnoringCancellationTransport: CmxByteTransport {
    private var connects = 0

    func connect() async throws {
        connects += 1
        let startedAt = Date()
        while Date().timeIntervalSince(startedAt) < 0.2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
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
}
