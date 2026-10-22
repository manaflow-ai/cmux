public import Foundation

/// The daemon's tailnet node as `tailnet.state` and `tailnet.login.start` report it
/// (`TailnetState`): `state` is the node's backend state in snake case (`not_started`,
/// `starting`, `needs_login`, `needs_machine_auth`, `running`, `stopped`, `error`, ...).
public nonisolated struct TailnetNodeState: Decodable, Equatable, Sendable {
    public nonisolated struct Owner: Decodable, Equatable, Sendable {
        public var loginName: String
        public var displayName: String

        enum CodingKeys: String, CodingKey {
            case loginName = "login_name"
            case displayName = "display_name"
        }
    }

    public var state: String
    /// The sign-in link while the node needs a login: a credential until it is used.
    public var browseToURL: String?
    /// `cosmic-gray-cmux.tail1234.ts.net.` once the node runs.
    public var dnsName: String?
    public var owner: Owner?
    public var ips: [String]?
    public var error: String?

    public init(state: String, browseToURL: String? = nil, dnsName: String? = nil, owner: Owner? = nil,
                ips: [String]? = nil, error: String? = nil) {
        self.state = state
        self.browseToURL = browseToURL
        self.dnsName = dnsName
        self.owner = owner
        self.ips = ips
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case state, owner, ips, error
        case browseToURL = "browse_to_url"
        case dnsName = "dns_name"
    }
}

/// Who the node serves, as the node's access check reads it (cmux-tailnet `Access`): the owner
/// always; the allow list; every member of the tailnet only when `allowTailnetMembers` is on.
/// The default serves only the person's own Tailscale account ("Limit access" on).
public nonisolated struct TailnetAccess: Codable, Equatable, Sendable {
    /// Always refused (`user:<login>` or `tag:<name>`).
    public var deny: [String] = []
    /// Served beside the owner (`user:<login>` or `tag:<name>`).
    public var allow: [String] = []
    /// Serve every user device the tailnet's ACLs let through (never tagged devices).
    public var allowTailnetMembers = false

    public init(deny: [String] = [], allow: [String] = [], allowTailnetMembers: Bool = false) {
        self.deny = deny
        self.allow = allow
        self.allowTailnetMembers = allowTailnetMembers
    }

    /// Settings' "Limit access to your Tailscale account": on unless every tailnet member may connect.
    public var limitedToAccount: Bool { !allowTailnetMembers }

    enum CodingKeys: String, CodingKey {
        case deny, allow
        case allowTailnetMembers = "allow_tailnet_members"
    }

    /// A stored value missing a field keeps that field's default (limited to the account).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deny = try c.decodeIfPresent([String].self, forKey: .deny) ?? []
        allow = try c.decodeIfPresent([String].self, forKey: .allow) ?? []
        allowTailnetMembers = try c.decodeIfPresent(Bool.self, forKey: .allowTailnetMembers) ?? false
    }
}

/// What a Pair code carries: this Mac's tailnet address and a single-use pairing ticket
/// (`cmux host ticket new`, `cmxt1.…`) for it. The other Mac reads it from the QR code or a
/// pasted link and redeems the ticket (`cmux host join`); only the ticket's secret proves anything.
///
/// Link: `cmux://pair?address=https%3A%2F%2Fname.tail1234.ts.net&ticket=cmxt1.…`.
public nonisolated struct TailnetPairLink: Equatable, Sendable {
    /// `https://name.tail1234.ts.net`: https and a host only.
    public var address: String
    public var ticket: String

    static let scheme = "cmux"
    static let host = "pair"
    static let ticketPrefix = "cmxt1."
    /// A ticket is about 300 bytes (`MAX_TICKET_BYTES` on the minter is 2048).
    static let maxTicketBytes = 2048

    public init?(address: String, ticket: String) {
        guard let address = Self.canonicalAddress(address), Self.isTicket(ticket) else { return nil }
        self.address = address
        self.ticket = ticket
    }

    /// The link the QR code encodes.
    public var url: String {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [URLQueryItem(name: "address", value: address), URLQueryItem(name: "ticket", value: ticket)]
        // `+` would read as a space in some decoders; tickets are URL-safe base64 without it.
        return components.string ?? ""
    }

    /// Reads a pair link (surrounding whitespace ignored); nil for anything else.
    public init?(link: String) {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text), components.scheme?.lowercased() == Self.scheme,
              components.host?.lowercased() == Self.host else { return nil }
        let items = components.queryItems ?? []
        guard let address = items.first(where: { $0.name == "address" })?.value,
              let ticket = items.first(where: { $0.name == "ticket" })?.value else { return nil }
        self.init(address: address, ticket: ticket)
    }

    /// `https://<host>` for a typed address (`name.tail1234.ts.net`, with or without https://, a
    /// trailing dot or slash); nil for another scheme, a path, a user, a port or no host.
    public static func canonicalAddress(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let components = URLComponents(string: text), components.scheme?.lowercased() == "https",
              components.user == nil, components.port == nil, components.query == nil, components.fragment == nil,
              ["", "/"].contains(components.path),
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        let label = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !label.contains(where: \.isEmpty),
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) else { return nil }
        return "https://" + host
    }

    static func isTicket(_ text: String) -> Bool {
        guard text.hasPrefix(ticketPrefix), text.utf8.count <= maxTicketBytes, text.count > ticketPrefix.count else { return false }
        return text.dropFirst(ticketPrefix.count).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
