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

/// What Pair shows: a single-use pairing ticket (`cmux host ticket new`, `cmxt1.…`) for this
/// Mac's tailnet address, as the line another Mac runs to pair (`cmux host join`, #23297), in
/// text and as a QR code. Only the ticket's secret proves anything. (A `cmux://` link the other
/// Mac's app opens comes with that receiver, in the client PR.)
public nonisolated struct TailnetPairCode: Equatable, Sendable {
    /// `https://name.tail1234.ts.net`: https and a host only.
    public var address: String
    public var ticket: String

    static let ticketPrefix = "cmxt1."
    /// A ticket is about 300 bytes (`MAX_TICKET_BYTES` on the minter is 2048).
    static let maxTicketBytes = 2048

    public init?(address: String, ticket: String) {
        guard let address = TailnetPairCode.canonicalAddress(address), Self.isTicket(ticket) else { return nil }
        self.address = address
        self.ticket = ticket
    }

    /// The line the other Mac runs: the ticket is URL-safe base64, quoted for any shell anyway.
    public var joinCommand: String { "cmux host join '\(ticket)'" }

    static func isTicket(_ text: String) -> Bool {
        guard text.hasPrefix(ticketPrefix), text.utf8.count <= maxTicketBytes, text.count > ticketPrefix.count else { return false }
        return text.dropFirst(ticketPrefix.count).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// Tailnet addresses as the card shows and dials them.
extension TailnetPairCode {
    /// `https://<host>` for a typed address (`name.tail1234.ts.net`, with or without https://, a
    /// trailing dot or slash); nil for another scheme, a path, a user, a port or no host.
    public nonisolated static func canonicalAddress(_ text: String) -> String? {
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
}
