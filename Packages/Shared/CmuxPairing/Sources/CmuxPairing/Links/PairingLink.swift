public import Foundation

/// The versioned `pair` and `attach` link grammar (b6-pairing.md section 4.1):
///
///     cmux://pair/1?o=<code>&h=<host>&t=<team>&k=<host key>&e=<unix s>&n=<name>
///     cmux://attach/1?h=<host>&t=<team>
///
/// Also accepted with the exact-bundle scheme (`cmux-ios-<bundle id>://`) and
/// as `https://cmux.com/app/<path>` (or `www.cmux.com`), the forms C16's router
/// hands over. Unknown query keys are ignored within a version.
public struct PairingLink: Hashable, Sendable {
    public static let version = "1"

    public var kind: PairingLinkKind

    public init(kind: PairingLinkKind) { self.kind = kind }

    /// Parses `url`; `now` decides expiry of a `pair` link.
    public init(url: URL, now: Date = Date()) throws(PairingLinkError) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw .notPairingLink }
        let segments = Self.pathSegments(components)
        guard let verb = segments.first, verb == "pair" || verb == "attach" else { throw .notPairingLink }
        guard segments.count == 2 else { throw segments.count < 2 ? .missingField("version") : .notPairingLink }
        guard segments[1] == Self.version else { throw .unsupportedVersion(segments[1]) }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil { query[item.name] = item.value ?? "" }
        func field(_ name: String, _ valid: (String) -> Bool) throws(PairingLinkError) -> String {
            guard let value = query[name], !value.isEmpty else { throw .missingField(name) }
            guard valid(value) else { throw .invalidField(name) }
            return value
        }
        let host = try field("h", Self.isHostID)
        let team = try field("t", Self.isTeamID)
        if verb == "attach" {
            kind = .attach(host: host, team: team)
            return
        }
        let code = try field("o", Self.isOfferCode)
        let key = try field("k") { Data(base64URLEncoded: $0)?.count == 32 && $0.count == 43 }
        let expires = try field("e") { Int64($0).map { $0 > 0 } ?? false }
        let name = try field("n") { (1...64).contains($0.count) }
        let expiresAt = Date(timeIntervalSince1970: TimeInterval(Int64(expires)!))
        guard expiresAt > now else { throw .expired }
        kind = .pair(PairingOffer(code: code, host: host, team: team, hostKey: key, expiresAt: expiresAt, name: name))
    }

    /// The canonical `cmux://` form (what a Mac encodes in its QR code).
    public var url: URL {
        var components = URLComponents()
        components.scheme = "cmux"
        let items: [(String, String)]
        switch kind {
        case .pair(let offer):
            components.host = "pair"
            items = [("o", offer.code), ("h", offer.host), ("t", offer.team), ("k", offer.hostKey),
                     ("e", String(Int64(offer.expiresAt.timeIntervalSince1970))), ("n", offer.name)]
        case .attach(let host, let team):
            components.host = "attach"
            items = [("h", host), ("t", team)]
        }
        components.path = "/" + Self.version
        // Percent-encode everything outside unreserved so `+` and `&` in names survive every parser.
        components.percentEncodedQuery = items.map { "\($0.0)=\(Self.encode($0.1))" }.joined(separator: "&")
        return components.url!
    }

    // MARK: - Grammar

    /// `cmux://pair/1` has host `pair`; `https://cmux.com/app/pair/1` has path `/app/pair/1`.
    private static func pathSegments(_ c: URLComponents) -> [String] {
        let path = c.path.split(separator: "/").map(String.init)
        switch c.scheme?.lowercased() {
        case "https":
            guard let host = c.host?.lowercased(), host == "cmux.com" || host == "www.cmux.com",
                  path.first == "app" else { return [] }
            return Array(path.dropFirst())
        case let scheme? where scheme == "cmux" || scheme.hasPrefix("cmux-ios-"):
            return (c.host.map { [$0] } ?? []) + path
        default:
            return []
        }
    }

    static func isOfferCode(_ s: String) -> Bool {
        s.count == 26 && s.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) }
    }

    static func isHostID(_ s: String) -> Bool { isID(s, prefixes: ["host_", "h_"]) }
    static func isTeamID(_ s: String) -> Bool { isID(s, prefixes: ["team_"]) }

    private static func isID(_ s: String, prefixes: [String]) -> Bool {
        guard let prefix = prefixes.first(where: s.hasPrefix) else { return false }
        let rest = s.dropFirst(prefix.count)
        return (2...64).contains(rest.count) && rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
