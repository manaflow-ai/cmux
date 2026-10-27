import Foundation
import NIOCore

/// Opens connections from the phone itself, for hosts an exit will not
/// serve (a paired Mac that is not allowed to dial them).
public struct DirectConnectBackend: SocksConnectBackend {
    public let connectTimeout: TimeAmount
    private let sockets: TunnelSocketTransport

    public init(connectTimeout: TimeAmount = .seconds(15), sockets: TunnelSocketTransport = TunnelSocketTransport()) {
        self.connectTimeout = connectTimeout
        self.sockets = sockets
    }

    public func open(host: String, port: Int) async throws -> any TunnelByteStream {
        do {
            let channel = try await sockets.connect(host: host, port: port, timeout: connectTimeout, relay: true)
            return try await NIOChannelByteStream.install(on: channel)
        } catch {
            throw openError(error)
        }
    }

    func openError(_ error: any Error) -> TunnelOpenError {
        if let failure = sockets.openError(error) { return failure }
        if let error = error as? ChannelError, case .connectTimeout = error { return .timedOut }
        return .generalFailure
    }
}
