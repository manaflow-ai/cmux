import CMUXMobileCore
import Foundation

/// Models a transport that cannot report whether its native connection closed.
struct UnobservedLivenessTransport: CmxByteTransport {
    let base: LivenessTransport

    func connect() async throws { try await base.connect() }
    func receive() async throws -> Data? { try await base.receive() }
    func send(_ data: Data) async throws { try await base.send(data) }
    func close() async { await base.close() }
}
