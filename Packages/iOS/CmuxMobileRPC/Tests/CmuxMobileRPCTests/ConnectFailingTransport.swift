import CMUXMobileCore
import Foundation

/// A transport whose `connect()` always fails, modeling an unreachable route.
/// Used to prove the session never reports a host send when the channel never
/// came up (issue #6084).
actor ConnectFailingTransport: CmxByteTransport {
    func connect() async throws { throw ConnectFailingTransportError() }
    func receive() async throws -> Data? { nil }
    func send(_ data: Data) async throws {}
    func close() async {}
}
