import Foundation

/// The minimal pairing-QR grammar for Tailscale routes.
///
/// Tailscale codes keep the v2 grammar so already-released clients can still
/// scan them:
/// `cmux-ios://attach?v=2&ub=<stack-user-id>&pc=<compat>&r=<host>:<port>[&r=<host>:<port>...]`.
///
/// The only metadata a Tailscale code carries is what the phone consults
/// before dialing: `ub`, the opaque Stack user id the account preflight
/// matches against the signed-in phone so a wrong-account scan fails fast
/// (#6028), and `pc`, the pairing compatibility level, which fielded
/// decoders default to 0 when absent — omitting it would spuriously fire the
/// cross-version pairing warning on every current phone. App version and
/// build (`av`/`ab`) only ever decorated that warning's message, so they are
/// no longer written; the decoder still reads them from older Macs' codes.
///
/// The grammar has these properties:
/// - **No auth token.** The owner's Stack access token is the host's sole
///   authorization gate; a token in the QR authorized nothing and made the
///   code look like a leaked credential.
/// - **No expiry.** Ticket age authorizes nothing, so a code that sat on
///   screen for an hour still pairs.
/// - **No display name, no device id, no build metadata.** All arrive
///   post-handshake from `mobile.host.status`; the decoder leaves
///   `macDeviceID` empty and the shell adopts the host-reported identity
///   once connected.
/// - **No loopback, ever.** v2 routes are Tailscale `host:port` only: the
///   encoder drops a DEBUG Mac's dev loopback route instead of encoding it,
///   the Mac refuses to mint a QR without a Tailscale route (it shows the
///   set-up-Tailscale guidance instead), and the decoder rejects loopback
///   hosts outright, so a scanned code can never point a phone at itself.
///   Loopback pairing for the simulator/dev flows uses the injected attach
///   URL path, not a QR. Dropping loopback is also the pairing-latency fix:
///   a scanned loopback route sorted first and made the phone dial itself
///   into an `NWConnection` `.waiting` black hole for the full request
///   timeout before the Tailscale route was ever tried.
///
/// The payloads are deliberately *not* wrapped in base64 JSON: anyone can read
/// the URL off the QR and see for themselves that it carries only an address.
/// Plain text is also smaller, which lowers the QR version (fewer, larger
/// modules) and makes the code scan faster from a Mac screen.
///
/// Compatibility: the Mac pairing window emits only a Tailscale pairing
/// payload. The retired v3 grammar (one bare peer EndpointID from the removed
/// transport) is rejected as an invalid code; it carried no route this build
/// can dial. Workspace-scoped tickets, dev loopback tickets, and every RPC
/// consumer keep the compact v1 JSON payload
/// (``CmxAttachTicketCompactCoder``), and the decoder keeps accepting both that
/// and the legacy full-key grammar.
public struct CmxPairingQRCode: Sendable {
    /// The newest grammar version this build can decode.
    ///
    /// Distinct from ``CmxAttachTicket/currentVersion`` (the ticket structure
    /// version): v1 URLs carry base64 JSON and v2 carries Tailscale routes.
    /// v3 (a bare peer EndpointID for the removed transport) is retired and
    /// intentionally not decodable.
    public static let version = 2

    private static let tailscaleVersion = 2

    /// Defensive cap on routes accepted from a scanned code. The Mac's route
    /// resolver emits at most a couple (MagicDNS name + Tailscale IP); a QR
    /// stuffed with dozens of routes is hostile input that would otherwise
    /// turn into a long chain of dial attempts.
    public static let maximumRouteCount = 8

    /// Creates the codec. It is stateless: construct one inline at the call
    /// site; every instance speaks the same grammar version.
    public init() {}

    /// Encode `ticket` as a minimal pairing URL, or `nil` when it does not
    /// qualify (see ``canEncode(_:routeDisclosureMode:)``); callers fall back
    /// to the compact v1 payload so every ticket still has an attach URL.
    ///
    /// Only the ticket's Tailscale routes are written; a DEBUG Mac's dev
    /// loopback route is dropped, never written into a scannable code.
    public func encode(
        _ ticket: CmxAttachTicket,
        routeDisclosureMode: CmxPairingRouteDisclosureMode,
        pairingURLScheme: CmxPairingURLScheme? =
            CmxPairingURLSchemeResolver().resolved
    ) -> String? {
        guard let scheme = pairingURLScheme?.rawValue else {
            return nil
        }
        let items: [String]
        switch routeDisclosureMode {
        case .legacyPrivateNetworkCompatibility:
            guard let routes = encodableTailscaleRoutes(of: ticket) else {
                return nil
            }
            var compatibilityItems: [String] = ["v=\(Self.tailscaleVersion)"]
            if let userID = normalizedNonEmpty(ticket.macUserID) {
                compatibilityItems.append("ub=\(percentEncodeQueryValue(userID))")
            }
            if let compatibilityVersion = ticket.macPairingCompatibilityVersion {
                compatibilityItems.append("pc=\(compatibilityVersion)")
            }
            compatibilityItems.append(contentsOf: routes.map { route -> String in
                guard case let .hostPort(host, port) = route.endpoint else {
                    // Unreachable: the selector admits host/port endpoints only.
                    return ""
                }
                return "r=\(hostPortString(host: host, port: port))"
            })
            items = compatibilityItems
        }
        // The scheme is channel-specific (see ``CmxPairingURLScheme``): a dev
        // Mac's QR opens the dev iOS build, a release Mac's QR opens the
        // release build, and the system camera can no longer hand a beta/prod
        // code to a dev build that also claimed the scheme.
        return "\(scheme)://attach?" + items.joined(separator: "&")
    }

    /// Whether `ticket` is expressible in the selected minimal grammar.
    public func canEncode(
        _ ticket: CmxAttachTicket,
        routeDisclosureMode: CmxPairingRouteDisclosureMode
    ) -> Bool {
        switch routeDisclosureMode {
        case .legacyPrivateNetworkCompatibility:
            encodableTailscaleRoutes(of: ticket) != nil
        }
    }

    /// The route subsequence a v2 pairing URL would carry for `ticket`, or
    /// `nil` when the ticket is not expressible in the minimal grammar.
    ///
    /// Expressible means: an unscoped pairing ticket whose Tailscale routes
    /// are exactly the canonical `host:port` sequence the decoder
    /// resynthesizes (ids `tailscale`, `tailscale_2`, ... and priorities 10,
    /// 20, ...), with no loopback host and no host that needs escaping.
    /// The only routes this grammar may silently drop are loopback ones (a
    /// DEBUG Mac's dev loopback route), which no phone may ever dial anyway.
    /// Anything else (workspace-scoped tickets, custom route ids, no
    /// Tailscale route at all, or a fallback route that the bare `host:port`
    /// grammar cannot express) keeps the compact v1 payload so the mapping
    /// stays lossless.
    private func encodableTailscaleRoutes(of ticket: CmxAttachTicket) -> [CmxAttachRoute]? {
        guard ticket.version == CmxAttachTicket.currentVersion,
              ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ticket.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            return nil
        }
        guard ticket.routes.allSatisfy({ $0.kind == .tailscale || CmxLoopbackHost().matches($0) }) else {
            return nil
        }
        let routes = ticket.routes.filter { $0.kind == .tailscale }
        guard !routes.isEmpty, routes.count <= Self.maximumRouteCount else {
            return nil
        }
        for (index, route) in routes.enumerated() {
            guard route.id == synthesizedRouteID(index: index),
                  route.priority == synthesizedRoutePriority(index: index),
                  case let .hostPort(host, _) = route.endpoint,
                  !CmxLoopbackHost().matches(host),
                  isPlainHost(host) else {
                return nil
            }
        }
        return routes
    }

    /// Whether `components` speaks a supported plain pairing-code grammar.
    ///
    /// v1 URLs carry a base64 JSON `payload` item instead.
    public func isPairingCodeURL(_ components: URLComponents) -> Bool {
        guard let version = Self.attachURLVersion(components) else {
            return false
        }
        return version == Self.tailscaleVersion
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

    /// Whether `rawValue` is a supported plain pairing URL.
    ///
    /// String-level convenience for callers that hold the encoded URL (the
    /// Mac's pairing window asserting the code it is about to display speaks
    /// the minimal grammar).
    public func isPairingCodeURLString(_ rawValue: String) -> Bool {
        guard let url = URL(string: rawValue),
              CmxPairingURLScheme(rawValue: url.scheme) != nil,
              url.host == "attach",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return isPairingCodeURL(components)
    }

    /// Decode a supported plain pairing URL into a validated ticket.
    ///
    /// The ticket comes back unscoped with an empty `macDeviceID`; the shell
    /// recovers the Mac's identity post-handshake from `mobile.host.status`.
    /// - Parameter components: A parsed v2 attach URL.
    /// - Throws: ``MobileSyncPairingPayloadError/invalidURL`` for malformed
    ///   input (including the retired v3 grammar, which carried only a route
    ///   for the removed transport) and
    ///   ``MobileSyncPairingPayloadError/loopbackRouteRejected``
    ///   when any route names a loopback host (a scanned code must never
    ///   point the phone at itself).
    public func decode(_ components: URLComponents) throws -> CmxAttachTicket {
        guard let version = Self.attachURLVersion(components) else {
            throw MobileSyncPairingPayloadError.invalidURL
        }
        switch version {
        case Self.tailscaleVersion:
            return try decodeTailscale(components)
        default:
            throw MobileSyncPairingPayloadError.invalidURL
        }
    }
}

private extension CmxPairingQRCode {
    /// Decode the v2 Tailscale compatibility grammar.
    func decodeTailscale(_ components: URLComponents) throws -> CmxAttachTicket {
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
