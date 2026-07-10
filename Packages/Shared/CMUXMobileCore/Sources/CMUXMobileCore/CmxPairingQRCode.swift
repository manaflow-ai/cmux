import Foundation

/// The minimal pairing-QR grammar: expected Mac account/build metadata plus
/// phone-reachable routes in the URL query.
///
/// v3:
/// `cmux-ios://attach?v=3&ub=<stack-user-id>&pc=<compat>&av=<version>&ab=<build>&i=<iroh-peer-id>&u=<relay-url>&d=<direct-addr>[&d=<direct-addr>...][&r=<host>:<port>...]`
///
/// v2 legacy:
/// `cmux-ios://attach?v=2&ub=<stack-user-id>&pc=<compat>&av=<version>&ab=<build>&r=<host>:<port>[&r=<host>:<port>...]`
///
/// A pairing QR needs to tell the phone where to dial and which non-secret
/// account/build context to check before dialing. The account value is the
/// opaque Stack user id, never the email itself. Everything else the earlier
/// grammars carried has a better channel or no reason to exist:
/// - **No auth token.** The owner's Stack access token is the host's sole
///   authorization gate; a token in the QR authorized nothing and made the
///   code look like a leaked credential.
/// - **No expiry.** Ticket age authorizes nothing, so a code that sat on
///   screen for an hour still pairs.
/// - **No display name, no device id.** Both arrive post-handshake from
///   `mobile.host.status`; the decoder leaves `macDeviceID` empty and the
///   shell adopts the host-reported identity once connected.
/// - **No loopback, ever.** The encoder drops a DEBUG Mac's dev loopback route
///   instead of encoding it, the Mac refuses to mint a QR without either an
///   iroh peer route or a Tailscale route, and the decoder rejects loopback
///   hosts outright, so a scanned code can never point a phone at itself.
///   Loopback pairing for the simulator/dev flows uses the injected attach
///   URL path, not a QR. Dropping loopback is also the pairing-latency fix:
///   a scanned loopback route sorted first and made the phone dial itself
///   into an `NWConnection` `.waiting` black hole for the full request
///   timeout before the Tailscale route was ever tried.
///
/// The payload is deliberately *not* wrapped in base64 JSON: anyone can read
/// the URL off the QR and see for themselves that it carries only an address.
/// Plain text is also smaller, which lowers the QR version (fewer, larger
/// modules) and makes the code scan faster from a Mac screen.
///
/// Compatibility: this grammar only ever appears in the Mac's pairing QR.
/// Workspace-scoped tickets, dev loopback tickets, and every RPC consumer
/// keep the compact v1 JSON payload (``CmxAttachTicketCompactCoder``), and the
/// decoder keeps accepting both that and the legacy full-key grammar.
public struct CmxPairingQRCode: Sendable {
    /// The grammar version carried in the URL's `v` query item. Distinct from
    /// ``CmxAttachTicket/currentVersion`` (the ticket *structure* version):
    /// `v=1` URLs carry a base64 JSON `payload`, `v=2` URLs carry bare
    /// Tailscale routes, and `v=3` URLs can carry an iroh peer route plus
    /// Tailscale fallback routes.
    public static let version = 3
    private static let legacyTailscaleOnlyVersion = 2

    /// Defensive cap on routes accepted from a scanned code. The Mac's route
    /// resolver emits at most a couple (MagicDNS name + Tailscale IP); a QR
    /// stuffed with dozens of routes is hostile input that would otherwise
    /// turn into a long chain of dial attempts.
    public static let maximumRouteCount = 8

    /// Creates the codec. It is stateless: construct one inline at the call
    /// site; every instance speaks the same grammar version.
    public init() {}

    /// Encode `ticket` as a v3 pairing URL, or `nil` when the ticket does not
    /// qualify (see ``canEncode(_:)``); callers fall back to the compact v1
    /// payload so every ticket still has an attach URL.
    ///
    /// The ticket's iroh peer route and Tailscale fallback routes are encoded:
    /// a DEBUG Mac's dev loopback route is dropped, never written into a
    /// scannable code.
    public func encode(_ ticket: CmxAttachTicket) -> String? {
        guard let routes = encodableRoutes(of: ticket) else {
            return nil
        }
        var items: [String] = ["v=\(Self.version)"]
        if let userID = normalizedNonEmpty(ticket.macUserID) {
            items.append("ub=\(percentEncodeQueryValue(userID))")
        }
        if let compatibilityVersion = ticket.macPairingCompatibilityVersion {
            items.append("pc=\(compatibilityVersion)")
        }
        if let version = normalizedNonEmpty(ticket.macAppVersion) {
            items.append("av=\(percentEncodeQueryValue(version))")
        }
        if let build = normalizedNonEmpty(ticket.macAppBuild) {
            items.append("ab=\(percentEncodeQueryValue(build))")
        }
        if let irohRoute = routes.iroh {
            guard case let .peer(peerID, _, directAddrs, relayURL) = irohRoute.endpoint else {
                return nil
            }
            items.append("i=\(percentEncodeQueryValue(peerID))")
            if let relayURL = normalizedNonEmpty(relayURL) {
                items.append("u=\(percentEncodeQueryValue(relayURL))")
            }
            for directAddr in directAddrs.compactMap({ normalizedNonEmpty($0) }) {
                items.append("d=\(percentEncodeQueryValue(directAddr))")
            }
        }
        let routeItems = routes.tailscale.map { route -> String in
            guard case let .hostPort(host, port) = route.endpoint else {
                // Unreachable: `encodableRoutes` admits host/port endpoints only.
                return ""
            }
            return "r=\(hostPortString(host: host, port: port))"
        }
        items.append(contentsOf: routeItems)
        // The scheme is channel-specific (see ``CmxPairingURLScheme``): a dev
        // Mac's QR opens the dev iOS build, a release Mac's QR opens the
        // release build, and the system camera can no longer hand a beta/prod
        // code to a dev build that also claimed the scheme.
        return "\(CmxPairingURLScheme.current)://attach?" + items.joined(separator: "&")
    }

    /// Whether `ticket` is expressible in the minimal grammar; see
    /// ``encodableRoutes(of:)`` for the rules.
    public func canEncode(_ ticket: CmxAttachTicket) -> Bool {
        encodableRoutes(of: ticket) != nil
    }

    /// The route subsequence a v3 pairing URL would carry for `ticket`, or
    /// `nil` when the ticket is not expressible in the minimal grammar.
    ///
    /// Expressible means: an unscoped pairing ticket with at most one canonical
    /// iroh peer route plus canonical Tailscale `host:port` fallbacks (ids
    /// `tailscale`, `tailscale_2`, ... and priorities 10, 20, ...), with no
    /// loopback host and no host that needs escaping. The only routes this
    /// grammar may silently drop are loopback ones (a DEBUG Mac's dev loopback
    /// route), which no phone may ever dial anyway.
    private func encodableRoutes(of ticket: CmxAttachTicket) -> EncodableRoutes? {
        guard ticket.version == CmxAttachTicket.currentVersion,
              ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ticket.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            return nil
        }
        guard ticket.routes.allSatisfy({
            $0.kind == .tailscale || $0.kind == .iroh || CmxLoopbackHost().matches($0)
        }) else {
            return nil
        }
        let irohRoutes = ticket.routes.filter { $0.kind == .iroh }
        guard irohRoutes.count <= 1 else {
            return nil
        }
        let irohRoute = irohRoutes.first
        if let irohRoute {
            guard irohRoute.id == CmxAttachTransportKind.iroh.rawValue,
                  irohRoute.priority == irohRoutePriority,
                  case let .peer(peerID, _, directAddrs, relayURL) = irohRoute.endpoint,
                  normalizedNonEmpty(peerID) != nil,
                  directAddrs.allSatisfy({ normalizedNonEmpty($0) != nil }),
                  relayURL == nil || normalizedNonEmpty(relayURL) != nil else {
                return nil
            }
        }
        let tailscaleRoutes = ticket.routes.filter { $0.kind == .tailscale }
        guard (irohRoute == nil ? tailscaleRoutes.count : tailscaleRoutes.count + 1) > 0,
              tailscaleRoutes.count + (irohRoute == nil ? 0 : 1) <= Self.maximumRouteCount else {
            return nil
        }
        for (index, route) in tailscaleRoutes.enumerated() {
            guard route.id == synthesizedRouteID(index: index),
                  route.priority == synthesizedRoutePriority(index: index),
                  case let .hostPort(host, _) = route.endpoint,
                  !CmxLoopbackHost().matches(host),
                  isPlainHost(host) else {
                return nil
            }
        }
        return EncodableRoutes(iroh: irohRoute, tailscale: tailscaleRoutes)
    }

    /// Whether `components` (an already-parsed `cmux-ios://attach` URL) speaks
    /// a supported pairing-code grammar. v1 URLs carry the base64 `payload`
    /// item instead.
    public func isPairingCodeURL(_ components: URLComponents) -> Bool {
        guard let rawVersion = components.queryItems?.first(where: { $0.name == "v" })?.value,
              let version = Int(rawVersion) else {
            return false
        }
        return version == Self.legacyTailscaleOnlyVersion || version == Self.version
    }

    /// The integer grammar version declared by an attach URL's `v` query item,
    /// or `nil` when absent or non-numeric. Used to tell a *newer* grammar
    /// (`v` greater than ``version``) apart from a malformed code so the user is
    /// told to update the app instead of seeing the generic invalid-code copy.
    public static func attachURLVersion(_ components: URLComponents) -> Int? {
        guard let raw = components.queryItems?.first(where: { $0.name == "v" })?.value else {
            return nil
        }
        return Int(raw)
    }

    /// Whether `rawValue` is a supported pairing URL. String-level convenience for
    /// callers that hold the encoded URL (the Mac's pairing window asserting
    /// the code it is about to display speaks the minimal grammar).
    public func isPairingCodeURLString(_ rawValue: String) -> Bool {
        guard let url = URL(string: rawValue),
              CmxPairingURLScheme.isPairingScheme(url.scheme),
              url.host == "attach",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return isPairingCodeURL(components)
    }

    /// Decode a supported pairing URL into a validated ``CmxAttachTicket``.
    ///
    /// The ticket comes back unscoped with an empty `macDeviceID`; the shell
    /// recovers the Mac's identity post-handshake from `mobile.host.status`.
    /// - Parameter components: The parsed `cmux-ios://attach?v=<version>&...` URL.
    /// - Throws: ``MobileSyncPairingPayloadError/invalidURL`` for malformed
    ///   input and ``MobileSyncPairingPayloadError/loopbackRouteRejected``
    ///   when any route names a loopback host (a scanned code must never
    ///   point the phone at itself).
    public func decode(_ components: URLComponents) throws -> CmxAttachTicket {
        guard isPairingCodeURL(components) else {
            throw MobileSyncPairingPayloadError.invalidURL
        }
        let version = Self.attachURLVersion(components)
        switch version {
        case .some(Self.legacyTailscaleOnlyVersion):
            return try decodeLegacyTailscaleOnly(components)
        case .some(Self.version):
            return try decodeCurrent(components)
        default:
            throw MobileSyncPairingPayloadError.invalidURL
        }
    }
}
private extension CmxPairingQRCode {
    struct EncodableRoutes {
        let iroh: CmxAttachRoute?
        let tailscale: [CmxAttachRoute]
    }

    var irohRoutePriority: Int { 5 }

    func decodeLegacyTailscaleOnly(_ components: URLComponents) throws -> CmxAttachTicket {
        let rawRoutes = (components.queryItems ?? [])
            .filter { $0.name == "r" }
            .compactMap(\.value)
        guard !rawRoutes.isEmpty, rawRoutes.count <= Self.maximumRouteCount else {
            throw MobileSyncPairingPayloadError.invalidURL
        }
        let routes = try rawRoutes.enumerated().map { index, rawRoute -> CmxAttachRoute in
            let (host, port) = try parseHostPort(rawRoute)
            guard !CmxLoopbackHost().matches(host) else {
                throw MobileSyncPairingPayloadError.loopbackRouteRejected
            }
            return try CmxAttachRoute(
                id: synthesizedRouteID(index: index),
                kind: .tailscale,
                endpoint: .hostPort(host: host, port: port),
                priority: synthesizedRoutePriority(index: index)
            )
        }
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "",
            macDisplayName: nil,
            macUserEmail: queryValue(named: "e", in: components),
            macUserID: queryValue(named: "ub", in: components),
            macPairingCompatibilityVersion: queryInt(named: "pc", in: components) ?? 0,
            macAppVersion: queryValue(named: "av", in: components),
            macAppBuild: queryValue(named: "ab", in: components),
            routes: routes,
            expiresAt: nil,
            authToken: nil
        )
        try ticket.validate()
        return ticket
    }

    func decodeCurrent(_ components: URLComponents) throws -> CmxAttachTicket {
        let queryItems = components.queryItems ?? []
        let rawRoutes = queryItems
            .filter { $0.name == "r" }
            .compactMap(\.value)
        let peerID = queryValue(named: "i", in: components)
        let routeCount = rawRoutes.count + (peerID == nil ? 0 : 1)
        guard routeCount > 0, routeCount <= Self.maximumRouteCount else {
            throw MobileSyncPairingPayloadError.invalidURL
        }

        var routes: [CmxAttachRoute] = []
        if let peerID {
            let directAddrs = queryItems
                .filter { $0.name == "d" }
                .compactMap { normalizedNonEmpty($0.value) }
            let relayURL = queryValue(named: "u", in: components)
            routes.append(try CmxAttachRoute(
                id: CmxAttachTransportKind.iroh.rawValue,
                kind: .iroh,
                endpoint: .peer(
                    id: peerID,
                    relayHint: nil,
                    directAddrs: directAddrs,
                    relayURL: relayURL
                ),
                priority: irohRoutePriority
            ))
        }

        let tailscaleRoutes = try rawRoutes.enumerated().map { index, rawRoute -> CmxAttachRoute in
            let (host, port) = try parseHostPort(rawRoute)
            guard !CmxLoopbackHost().matches(host) else {
                throw MobileSyncPairingPayloadError.loopbackRouteRejected
            }
            return try CmxAttachRoute(
                id: synthesizedRouteID(index: index),
                kind: .tailscale,
                endpoint: .hostPort(host: host, port: port),
                priority: synthesizedRoutePriority(index: index)
            )
        }
        routes.append(contentsOf: tailscaleRoutes)

        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "",
            macDisplayName: nil,
            macUserEmail: queryValue(named: "e", in: components),
            macUserID: queryValue(named: "ub", in: components),
            macPairingCompatibilityVersion: queryInt(named: "pc", in: components) ?? 0,
            macAppVersion: queryValue(named: "av", in: components),
            macAppBuild: queryValue(named: "ab", in: components),
            routes: routes,
            expiresAt: nil,
            authToken: nil
        )
        try ticket.validate()
        return ticket
    }

    /// The route id the Mac's route resolver mints for the route at `index`
    /// (`tailscale` for the first, `tailscale_N` after).
    func synthesizedRouteID(index: Int) -> String {
        index == 0
            ? CmxAttachTransportKind.tailscale.rawValue
            : "\(CmxAttachTransportKind.tailscale.rawValue)_\(index + 1)"
    }

    /// The priority the Mac's route resolver assigns the route at `index`.
    func synthesizedRoutePriority(index: Int) -> Int {
        10 + index * 10
    }

    /// `host:port`, bracketing IPv6 literals.
    func hostPortString(host: String, port: Int) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Parse `host:port` (with optional IPv6 brackets) from a query value.
    func parseHostPort(_ rawValue: String) throws -> (String, Int) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: Substring
        let portText: Substring
        if trimmed.hasPrefix("[") {
            guard let closing = trimmed.firstIndex(of: "]"),
                  closing > trimmed.startIndex else {
                throw MobileSyncPairingPayloadError.invalidURL
            }
            host = trimmed[trimmed.index(after: trimmed.startIndex)..<closing]
            let afterBracket = trimmed.index(after: closing)
            guard afterBracket < trimmed.endIndex, trimmed[afterBracket] == ":" else {
                throw MobileSyncPairingPayloadError.invalidURL
            }
            portText = trimmed[trimmed.index(after: afterBracket)...]
        } else {
            guard let separator = trimmed.lastIndex(of: ":") else {
                throw MobileSyncPairingPayloadError.invalidURL
            }
            host = trimmed[..<separator]
            portText = trimmed[trimmed.index(after: separator)...]
        }
        guard !host.isEmpty, isPlainHost(String(host)) else {
            throw MobileSyncPairingPayloadError.invalidURL
        }
        guard let port = Int(portText), (1...65535).contains(port) else {
            throw MobileSyncPairingPayloadError.invalidPort(Int(portText) ?? 0)
        }
        return (String(host), port)
    }

    /// Whether `host` is a bare DNS name or IP literal that needs no escaping
    /// in a URL query (letters, digits, `.`, `-`, `_`, and `:` for IPv6).
    func isPlainHost(_ host: String) -> Bool {
        !host.isEmpty && host.utf8.allSatisfy { byte in
            (48...57).contains(byte)        // 0-9
                || (65...90).contains(byte) // A-Z
                || (97...122).contains(byte) // a-z
                || byte == UInt8(ascii: ".")
                || byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: "_")
                || byte == UInt8(ascii: ":")
        }
    }

    func queryValue(named name: String, in components: URLComponents) -> String? {
        normalizedNonEmpty(components.queryItems?.first(where: { $0.name == name })?.value)
    }

    func queryInt(named name: String, in components: URLComponents) -> Int? {
        guard let value = queryValue(named: name, in: components) else { return nil }
        return Int(value)
    }

    func normalizedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    func percentEncodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
