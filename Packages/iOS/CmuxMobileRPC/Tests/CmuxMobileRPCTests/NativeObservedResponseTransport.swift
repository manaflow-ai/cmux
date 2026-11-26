import CMUXMobileCore
import Foundation

/// Supplies the same independent connection-state snapshot as the Iroh adapter.
struct NativeObservedResponseTransport: CmxByteTransport, CmxByteTransportLivenessObserving {
    let base: ControllableResponseTransport

    func connect() async throws { try await base.connect() }
    func send(_ data: Data) async throws { try await base.send(data) }
    func receive() async throws -> Data? { try await base.receive() }
    func close() async { await base.close() }
    func isTransportClosed() async -> Bool { await base.closed() }
}
