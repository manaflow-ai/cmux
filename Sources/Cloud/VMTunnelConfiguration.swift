import Foundation

/// A wg-quick config in the shape a `NEPacketTunnelProvider` needs, with the
/// private key structurally absent.
///
/// `NETunnelProviderProtocol.providerConfiguration` is persisted by the system
/// into the VPN preferences, which are readable by root and captured by backups
/// — so the tunnel's private key must not travel in it. This type cannot carry
/// one: there is no field for it. The key stays in the app-written 0600 config
/// at `~/.cmuxterm/wireguard/<interface>.conf`, and the provider receives it
/// through `passwordReference`, a keychain persistent reference. That is a
/// structural guarantee rather than a review promise, which is the point.
struct VMTunnelConfiguration: Equatable, Sendable {
    struct Interface: Equatable, Sendable {
        /// `Address =` values, prefix length included (`10.0.7.3/32`).
        var addresses: [String]
        var dnsServers: [String]
        var searchDomains: [String]
        var mtu: Int?
    }

    struct Peer: Equatable, Sendable {
        var publicKey: String
        var presharedKey: String?
        /// `host:port`, unresolved. The provider resolves it at start so a
        /// changed provider-side address is picked up without re-enrolling.
        var endpoint: String?
        var allowedIPs: [String]
        var persistentKeepalive: Int?
    }

    var interface: Interface
    var peers: [Peer]

    enum ParseError: Error, CustomStringConvertible {
        case noInterfaceSection
        case noPeerSection
        case noAddresses
        case peerWithoutPublicKey

        var description: String {
            switch self {
            case .noInterfaceSection: return "the tunnel config has no [Interface] section"
            case .noPeerSection: return "the tunnel config has no [Peer] section"
            case .noAddresses: return "the tunnel config's [Interface] has no Address"
            case .peerWithoutPublicKey: return "a [Peer] in the tunnel config has no PublicKey"
            }
        }
    }

    /// Parse the config this Mac already wrote for `wg-quick`, so the two
    /// backends are driven from one artifact instead of two divergent
    /// representations of the same enrollment.
    init(wgQuickConfig config: String) throws {
        var sawInterface = false
        var interface = Interface(addresses: [], dnsServers: [], searchDomains: [], mtu: nil)
        var peers: [Peer] = []
        var current: Peer?

        func flushPeer() throws {
            guard let peer = current else { return }
            guard !peer.publicKey.isEmpty else { throw ParseError.peerWithoutPublicKey }
            peers.append(peer)
            current = nil
        }

        for rawLine in config.components(separatedBy: "\n") {
            // wg-quick treats `#` as a comment to end of line.
            let withoutComment = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? rawLine
            let line = withoutComment.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                let section = line.lowercased()
                if section == "[interface]" {
                    try flushPeer()
                    sawInterface = true
                } else if section == "[peer]" {
                    try flushPeer()
                    current = Peer(publicKey: "", presharedKey: nil, endpoint: nil, allowedIPs: [], persistentKeepalive: nil)
                } else {
                    try flushPeer()
                }
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if current != nil {
                switch key {
                case "publickey": current?.publicKey = value
                case "presharedkey": current?.presharedKey = value.isEmpty ? nil : value
                case "endpoint": current?.endpoint = value.isEmpty ? nil : value
                case "allowedips": current?.allowedIPs = Self.commaSeparated(value)
                case "persistentkeepalive": current?.persistentKeepalive = Int(value)
                default: break
                }
                continue
            }
            guard sawInterface else { continue }
            switch key {
            case "address": interface.addresses.append(contentsOf: Self.commaSeparated(value))
            case "dns":
                // wg-quick's DNS accepts both resolvers and search domains in
                // one list; anything that is not an IP literal is a domain.
                for entry in Self.commaSeparated(value) {
                    if Self.isIPLiteral(entry) {
                        interface.dnsServers.append(entry)
                    } else {
                        interface.searchDomains.append(entry)
                    }
                }
            case "mtu": interface.mtu = Int(value)
            default: break
            }
        }
        try flushPeer()

        guard sawInterface else { throw ParseError.noInterfaceSection }
        guard !interface.addresses.isEmpty else { throw ParseError.noAddresses }
        guard !peers.isEmpty else { throw ParseError.noPeerSection }
        self.interface = interface
        self.peers = peers
    }

    /// The `providerConfiguration` dictionary handed to the packet-tunnel
    /// provider. Property-list types only — the system rejects anything else —
    /// and no private key, by construction.
    var providerConfiguration: [String: Any] {
        var dict: [String: Any] = [
            "addresses": interface.addresses,
            "peers": peers.map { peer -> [String: Any] in
                var entry: [String: Any] = [
                    "public_key": peer.publicKey,
                    "allowed_ips": peer.allowedIPs,
                ]
                if let presharedKey = peer.presharedKey { entry["preshared_key"] = presharedKey }
                if let endpoint = peer.endpoint { entry["endpoint"] = endpoint }
                if let keepalive = peer.persistentKeepalive { entry["persistent_keepalive"] = keepalive }
                return entry
            },
        ]
        if !interface.dnsServers.isEmpty { dict["dns_servers"] = interface.dnsServers }
        if !interface.searchDomains.isEmpty { dict["search_domains"] = interface.searchDomains }
        if let mtu = interface.mtu { dict["mtu"] = mtu }
        return dict
    }

    /// What System Settings shows as the VPN's server, and what a user
    /// recognises in the VPN list. First peer endpoint's host, since this
    /// tunnel has exactly one peer (the network's gateway).
    var serverAddress: String? {
        guard let endpoint = peers.first?.endpoint, !endpoint.isEmpty else { return nil }
        // Strip the port, keeping IPv6 literals in brackets intact.
        if endpoint.hasPrefix("["), let close = endpoint.firstIndex(of: "]") {
            return String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
        }
        // Exactly one colon means `host:port`; more means a bare IPv6 literal,
        // which has no port to strip.
        if endpoint.filter({ $0 == ":" }).count == 1, let colon = endpoint.lastIndex(of: ":") {
            return String(endpoint[endpoint.startIndex..<colon])
        }
        return endpoint
    }

    private static func commaSeparated(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func isIPLiteral(_ value: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, value, &v4) == 1 { return true }
        var v6 = in6_addr()
        return inet_pton(AF_INET6, value, &v6) == 1
    }
}
