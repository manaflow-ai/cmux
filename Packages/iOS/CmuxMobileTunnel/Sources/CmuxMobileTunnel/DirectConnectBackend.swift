import Foundation
import NIOCore
import NIOTransportServices
import Network

/// Opens connections from the phone itself, for hosts an exit will not
/// serve (a paired Mac that is not allowed to dial them).
public struct DirectConnectBackend: SocksConnectBackend {
    public let connectTimeout: TimeAmount

    public init(connectTimeout: TimeAmount = .seconds(15)) {
        self.connectTimeout = connectTimeout
    }

    public func open(host: String, port: Int) async throws -> any TunnelByteStream {
        do {
            let channel = try await NIOTSConnectionBootstrap(group: NIOTSEventLoopGroup.singleton)
                .connectTimeout(connectTimeout)
                .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .channelOption(ChannelOptions.autoRead, value: false)
                .connect(host: host, port: port)
                .get()
            return try await NIOChannelByteStream.install(on: channel)
        } catch {
            throw Self.openError(error)
        }
    }

    static func openError(_ error: any Error) -> TunnelOpenError {
        if let error = error as? NWError, case .posix(let code) = error {
            switch code {
            case .ECONNREFUSED: return .connectionRefused
            case .EHOSTUNREACH, .EHOSTDOWN: return .hostUnreachable
            case .ENETUNREACH, .ENETDOWN: return .networkUnreachable
            case .ETIMEDOUT: return .timedOut
            default: return .generalFailure
            }
        }
        if let error = error as? ChannelError, case .connectTimeout = error { return .timedOut }
        if case .dns = error as? NWError { return .hostUnreachable }
        return .generalFailure
    }
}

/// Destinations that mean "the exit machine itself": `localhost`,
/// `*.localhost` (RFC 6761), `127.0.0.0/8`, `::1`, and the unspecified
/// addresses browsers treat as local.
public enum TunnelLoopbackHost {
    public static func isLoopback(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host == "0.0.0.0" || host == "::" { return true }
        if let v6 = IPv6Address(host) {
            if v6 == .loopback { return true }
            if let mapped = v6.asIPv4 { return mapped.isLoopback }
            return false
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.first == "127" && octets.allSatisfy { UInt8($0) != nil }
    }
}
