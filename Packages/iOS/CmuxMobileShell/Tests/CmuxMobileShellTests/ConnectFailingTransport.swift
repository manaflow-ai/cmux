import CMUXMobileCore
import Foundation

/// A transport whose `connect()` always fails, modeling an unreachable route.
actor ConnectFailingTransport: CmxByteTransport {
    func connect() async throws { throw ConnectFailingTransportError() }
    func receive() async throws -> Data? { nil }
    func send(_ data: Data) async throws {}
    func close() async {}
}
