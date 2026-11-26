import Foundation
import Network

/// The existing unix socket transport for a one-shot acpmux request.
nonisolated struct AcpmuxSocketTransport: AcpmuxRPCTransport {
    let connection: NWConnection

    func start() async throws { try await AcpmuxStatusClient.start(connection) }
    func send(_ data: Data) async throws { try await AcpmuxStatusClient.send(data, on: connection) }
    func receive() async throws -> Data? { try await AcpmuxStatusClient.receive(on: connection) }
}
