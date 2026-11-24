import Foundation
import NIOCore
#if !canImport(Network)
import NIOPosix
#endif
#if canImport(Network)
import Network
#endif

/// Opens connections from the phone itself, for hosts an exit will not
/// serve (a paired Mac that is not allowed to dial them).
public struct DirectConnectBackend: SocksConnectBackend {
    public let connectTimeout: TimeAmount

    public init(connectTimeout: TimeAmount = .seconds(15)) {
        self.connectTimeout = connectTimeout
    }

    public func open(host: String, port: Int) async throws -> any TunnelByteStream {
        do {
            let channel = try await TunnelTransport.connect(host: host, port: port, timeout: connectTimeout)
            return try await NIOChannelByteStream.install(on: channel)
        } catch {
            throw Self.openError(error)
        }
    }

    static func openError(_ error: any Error) -> TunnelOpenError {
        #if canImport(Network)
        if let error = error as? NWError, case .posix(let code) = error {
            switch code {
            case .ECONNREFUSED: return .connectionRefused
            case .EHOSTUNREACH, .EHOSTDOWN: return .hostUnreachable
            case .ENETUNREACH, .ENETDOWN: return .networkUnreachable
            case .ETIMEDOUT: return .timedOut
            default: return .generalFailure
            }
        }
        if case .dns = error as? NWError { return .hostUnreachable }
        #else
        if let error = error as? IOError {
            switch error.errnoCode {
            case ECONNREFUSED: return .connectionRefused
            case EHOSTUNREACH, EHOSTDOWN: return .hostUnreachable
            case ENETUNREACH, ENETDOWN: return .networkUnreachable
            case ETIMEDOUT: return .timedOut
            default: return .generalFailure
            }
        }
        #endif
        if let error = error as? ChannelError, case .connectTimeout = error { return .timedOut }
        return .generalFailure
    }
}
