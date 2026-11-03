public import Foundation

/// A completed wg-quick config for the Cloud Tunnel's `browser` peer, and what the packet tunnel
/// needs from it: this Mac's addresses inside the Cloud network, the routes that enter the tunnel,
/// the MTU and the WireGuard endpoint's host.
///
/// The text holds the private key. It travels only inside the `NETunnelProviderProtocol`
/// `providerConfiguration`, which macOS keeps in the NetworkExtension preferences (readable by
/// root, not the keychain), and is never logged: ``description`` leaves it out.
///
/// ```swift
/// let configuration = try CloudTunnelConfiguration(wgQuick: completedConfig)
/// configuration.routes // ["10.192.0.0/20"]
/// ```
public struct CloudTunnelConfiguration: Sendable, Equatable, CustomStringConvertible {
    /// Why a config cannot drive the tunnel.
    public enum ParseError: Error, Sendable, Equatable {
        /// No `PrivateKey` in `[Interface]`: the app did not complete the server's config.
        case missingPrivateKey
        /// No `Address` in `[Interface]`.
        case missingAddress
        /// No `AllowedIPs` in `[Peer]`: nothing would enter the tunnel.
        case missingRoutes
        /// No `Endpoint` in `[Peer]`.
        case missingEndpoint
        /// A value that is not an address, a CIDR or a number.
        case invalid(String)
        /// A route outside the Cloud's private ranges (``CloudTunnelCIDR/isCloudRoute``): it would
        /// send other traffic of this Mac into the tunnel.
        case notACloudRoute(String)
    }

    /// The wg-quick text, private key included; handed to the engine as is.
    public let wgQuick: String
    /// This Mac's addresses inside the Cloud network, as `address/prefix`.
    public let addresses: [CloudTunnelCIDR]
    /// The networks that enter the tunnel (`AllowedIPs`): the Cloud VPCs, never a default route.
    public let routes: [CloudTunnelCIDR]
    /// Largest IP packet the tunnel carries; 1420 when the config does not say.
    public let mtu: Int
    /// The WireGuard endpoint's host (the Cloud gateway), the tunnel's remote address.
    public let endpointHost: String

    /// Parses a completed wg-quick config.
    ///
    /// - Parameter wgQuick: The server's config with this Mac's `PrivateKey` filled in.
    /// - Throws: ``ParseError`` when a field the tunnel needs is missing or malformed.
    public init(wgQuick: String) throws {
        var values: [String: [String]] = [:]
        var section = ""
        for raw in wgQuick.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                section = trimmed.dropFirst().dropLast().lowercased()
                continue
            }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = section + "." + trimmed[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            values[key, default: []].append(value)
        }
        func list(_ key: String) -> [String] {
            (values[key] ?? []).flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        guard values["interface.privatekey"]?.contains(where: { !$0.isEmpty }) == true else { throw ParseError.missingPrivateKey }
        let addresses = try list("interface.address").map { try CloudTunnelCIDR(parsing: $0) }
        guard !addresses.isEmpty else { throw ParseError.missingAddress }
        let routes = try list("peer.allowedips").map { try CloudTunnelCIDR(parsing: $0) }
        guard !routes.isEmpty else { throw ParseError.missingRoutes }
        if let route = routes.first(where: { !$0.isCloudRoute }) { throw ParseError.notACloudRoute(route.description) }
        guard let endpoint = values["peer.endpoint"]?.first, let host = Self.host(ofEndpoint: endpoint) else { throw ParseError.missingEndpoint }
        var mtu = 1420
        if let text = values["interface.mtu"]?.first {
            guard let value = Int(text), (576...65_535).contains(value) else { throw ParseError.invalid("MTU = \(text)") }
            mtu = value
        }
        self.wgQuick = wgQuick
        self.addresses = addresses
        self.routes = routes
        self.mtu = mtu
        self.endpointHost = host
    }

    /// `host:port` or `[v6]:port` to its host.
    static func host(ofEndpoint endpoint: String) -> String? {
        if endpoint.hasPrefix("["), let close = endpoint.firstIndex(of: "]") {
            let host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
            return host.isEmpty ? nil : host
        }
        guard let colon = endpoint.lastIndex(of: ":") else { return nil }
        let host = String(endpoint[..<colon])
        return host.isEmpty ? nil : host
    }

    /// The config without its private key.
    public var description: String {
        "CloudTunnelConfiguration(addresses: \(addresses), routes: \(routes), mtu: \(mtu), endpoint: \(endpointHost))"
    }
}
