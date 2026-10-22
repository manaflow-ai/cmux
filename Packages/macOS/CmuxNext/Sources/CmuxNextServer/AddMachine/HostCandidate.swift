public import Foundation

/// One Tailscale peer from `cmux-tui acp host candidates --json [--probe]`
/// (plans/cmux-next/add-machine-DESIGN.md): a machine the Add Machine card offers under its field.
public nonisolated struct HostCandidate: Equatable, Sendable, Identifiable, Decodable {
    public var name: String
    public var dnsName: String
    public var ip: String
    public var os: String
    public var online: Bool
    /// Already an acpmux peer of this Mac (its agents reach it). Not the same as in the app's
    /// machine list: a peer the app lacks stays pickable and is connected without a new enroll.
    public var alreadyPeer: Bool
    /// The peer's name and URL (`ssh://[user@]host[:port]`) when ``alreadyPeer``.
    public var peer: String?
    public var peerURL: String?
    /// Whether key-only ssh reached it (`--probe`); nil when not probed.
    public var sshOK: Bool?
    /// Already one of the app's SSH machines (set by the app, not the CLI): shown as Added, not offered.
    public var inApp: Bool

    public var id: String { dnsName.isEmpty ? name : dnsName }

    public init(name: String, dnsName: String, ip: String, os: String, online: Bool, alreadyPeer: Bool, sshOK: Bool? = nil,
                peer: String? = nil, peerURL: String? = nil, inApp: Bool = false) {
        self.name = name
        self.dnsName = dnsName
        self.ip = ip
        self.os = os
        self.online = online
        self.alreadyPeer = alreadyPeer
        self.peer = peer
        self.peerURL = peerURL
        self.sshOK = sshOK
        self.inApp = inApp
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case name, ip, os, online, peer
        case dnsName = "dns_name"
        case alreadyPeer = "already_peer"
        case peerURL = "peer_url"
        case sshOK = "ssh_ok"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        dnsName = try container.decodeIfPresent(String.self, forKey: .dnsName) ?? ""
        ip = try container.decodeIfPresent(String.self, forKey: .ip) ?? ""
        os = try container.decodeIfPresent(String.self, forKey: .os) ?? ""
        online = try container.decodeIfPresent(Bool.self, forKey: .online) ?? false
        alreadyPeer = try container.decodeIfPresent(Bool.self, forKey: .alreadyPeer) ?? false
        peer = try container.decodeIfPresent(String.self, forKey: .peer)
        peerURL = try container.decodeIfPresent(String.self, forKey: .peerURL)
        sshOK = try container.decodeIfPresent(Bool.self, forKey: .sshOK)
        inApp = false
    }

    /// What the field takes when the row is picked: an agent peer's own ssh destination (its
    /// `ssh://` URL's `[user@]host[:port]`, so a port it is reached on stays), else the MagicDNS
    /// name without its trailing dot, else the peer's name.
    public var destination: String {
        if let peerDestination { return peerDestination }
        let dns = dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName
        return dns.isEmpty ? name : dns
    }

    /// The `[user@]host[:port]` of an `ssh://` peer URL; nil for no peer or another transport.
    public var peerDestination: String? {
        guard alreadyPeer, let peerURL, peerURL.lowercased().hasPrefix("ssh://") else { return nil }
        let rest = peerURL.dropFirst("ssh://".count).split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? ""
        return rest.isEmpty ? nil : rest
    }

    /// Whether picking it can add it: online, not in the app yet, and ssh not known to be off. An
    /// agent peer's probe is not the answer: the probe dials its MagicDNS name on port 22, and the
    /// peer's own URL already reaches it.
    public var isPickable: Bool { online && !inApp && (alreadyPeer || sshOK != false) }

    /// The candidates of `host candidates --json` (`{"tailnet":…,"candidates":[…]}`), or a bare
    /// array; throws when the output is neither.
    public static func parseList(_ data: Data) throws -> [HostCandidate] {
        if let list = try? JSONDecoder().decode(Listing.self, from: data) { return list.candidates }
        return try JSONDecoder().decode([HostCandidate].self, from: data)
    }

    private nonisolated struct Listing: Decodable {
        var candidates: [HostCandidate]
    }
}

/// The candidate list under the Add Machine field.
public nonisolated enum HostCandidates: Equatable, Sendable {
    /// The plain `candidates` run runs (the spinner).
    case loading
    case loaded([HostCandidate])
    /// No Tailscale here, or the list failed: the list hides and the field stays.
    case unavailable
}
