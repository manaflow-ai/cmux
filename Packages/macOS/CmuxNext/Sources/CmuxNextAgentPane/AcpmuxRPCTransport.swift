import Foundation

/// One connected JSON-RPC byte stream. The handshake and the operation
/// share this transport, so a reconnect cannot change the advertised owner.
nonisolated protocol AcpmuxRPCTransport: Sendable {
    func start() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data?
}
