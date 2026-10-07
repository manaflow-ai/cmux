public import Foundation

/// Opens control-plane sockets. Production uses `URLSessionControlPlaneTransport`;
/// tests use an in-memory fake server.
public protocol ControlPlaneTransport: Sendable {
    func connect(url: URL, protocols: [String]) async throws -> any ControlPlaneConnection
}
