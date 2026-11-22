import Foundation

/// An explicitly entered local IROH address and UDP port. Never publish this value to a server.
public struct CmxIrohLocalSocketAddress: Equatable, Sendable {
    public let address: CmxIrohCustomPrivateAddress
    public let port: UInt16
    public var value: String { address.socketAddress(port: port) }

    /// Accepts IPv4:port or [IPv6]:port; a port is required and DNS names are rejected.
    public init(_ raw: String) throws {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        let portText: String
        if let bracketed = Substring(value).bracketedHost {
            host = String(bracketed.host)
            guard bracketed.rest.hasPrefix(":") else { throw CmxIrohCustomPrivateAddressError.invalidAddress }
            portText = String(bracketed.rest.dropFirst())
        } else {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw CmxIrohCustomPrivateAddressError.invalidAddress }
            host = String(parts[0]); portText = String(parts[1])
        }
        guard let port = UInt16(portText), port > 0, portText.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw CmxIrohCustomPrivateAddressError.invalidAddress
        }
        address = try CmxIrohCustomPrivateAddress(host)
        self.port = port
    }
}
