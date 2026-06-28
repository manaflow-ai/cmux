import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileTransport
import Foundation

actor SlowIgnoringCancellationTransport: CmxByteTransport {
    func connect() async throws {
        let startedAt = Date()
        while Date().timeIntervalSince(startedAt) < 0.2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CmxNetworkByteTransportError.connectionTimedOut
    }

    func receive() async throws -> Data? {
        nil
    }

    func send(_ data: Data) async throws {}

    func close() async {}
}
