import CMUXMobileCore
import Foundation

// Value types for `cmux remotes`: a parsed host:port attach spec and the
// flattened device-registry rows. Split from RemotesClient.swift so each file
// stays a single responsibility (pure DTOs/parsing here; the network client
// there) and under the Swift file-length budget.

/// One parsed `host:port` attach route for a manually-added remote, plus the
/// loopback decision. Pure value type so route parsing and the loopback refusal
/// are unit-testable without any network or running app.
public struct RemoteRouteSpec: Equatable, Sendable {
    public let host: String
    public let port: Int

    /// Parse a `host:port` string. Accepts bracketed IPv6 (`[::1]:51001`) and a
    /// trailing `:port`; rejects empty host, missing/out-of-range port, and
    /// loopback hosts (the same classifier the phone uses to reject a scanned
    /// loopback QR), so a remote a phone could never dial never reaches the
    /// registry.
    public static func parse(_ raw: String) throws -> RemoteRouteSpec {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RemotesClientError.invalidRoute(raw) }

        let host: String
        let portString: String
        if trimmed.hasPrefix("[") {
            // Bracketed IPv6 literal: `[<ipv6>]:<port>`.
            guard let close = trimmed.firstIndex(of: "]") else {
                throw RemotesClientError.invalidRoute(raw)
            }
            host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let afterBracket = trimmed[trimmed.index(after: close)...]
            guard afterBracket.hasPrefix(":") else {
                throw RemotesClientError.invalidRoute(raw)
            }
            portString = String(afterBracket.dropFirst())
        } else {
            // host:port — split on the LAST colon so a bare (unbracketed) IPv6
            // literal without a port is rejected rather than mis-split.
            guard let lastColon = trimmed.lastIndex(of: ":") else {
                throw RemotesClientError.invalidRoute(raw)
            }
            host = String(trimmed[trimmed.startIndex..<lastColon])
            portString = String(trimmed[trimmed.index(after: lastColon)...])
            // A bare IPv6 literal (multiple colons, no brackets) is ambiguous
            // and unsupported; require brackets for IPv6.
            if host.contains(":") {
                throw RemotesClientError.invalidRoute(raw)
            }
        }

        let cleanedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedHost.isEmpty else { throw RemotesClientError.invalidRoute(raw) }
        guard let port = Int(portString), (1...65535).contains(port) else {
            throw RemotesClientError.invalidRoute(raw)
        }
        if CmxLoopbackHost().matches(cleanedHost) {
            throw RemotesClientError.loopbackRoute(host: cleanedHost)
        }
        return RemoteRouteSpec(host: cleanedHost, port: port)
    }

    /// The `CmxAttachRoute` for this spec. Manual remotes are plain LAN/Tailscale
    /// host:port routes, so they use the `tailscale` transport kind (the route
    /// kind iOS treats as a directly-dialable host:port).
    public func attachRoute(id: String, priority: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: port),
            priority: priority
        )
    }

    /// Whether this route is a numeric Tailscale peer target safe to persist.
    ///
    /// A `*.ts.net` value is accepted as CLI input but is not attachable yet.
    /// ``RemotesClient`` must first match it to one authenticated local
    /// Tailscale status record and replace it with that record's numeric peer
    /// address. This keeps DNS names out of the iOS bearer transport entirely.
    public var isTailscaleAttachable: Bool {
        CmxTailscalePeerAddress(host) != nil
    }

    /// Whether this route is a syntactically valid fully qualified MagicDNS input.
    var isTailscaleMagicDNSInput: Bool {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasSuffix("."), normalized.count > 1 {
            normalized.removeLast()
        }
        return normalized.hasSuffix(".ts.net") && Self.isValidDNSHostname(normalized)
    }

    /// A syntactically valid DNS hostname: 1-253 chars, dot-separated labels of
    /// 1-63 chars using ASCII letters/digits/hyphens, no leading/trailing label
    /// hyphen.
    static func isValidDNSHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        for label in host.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty, label.count <= 63 else { return false }
            let chars = Array(label)
            let allValid = chars.allSatisfy { c in
                c.isASCII && (c.isLetter || c.isNumber || c == "-")
            }
            guard allValid, chars.first != "-", chars.last != "-" else { return false }
        }
        return true
    }

    public init(
        host: String,
        port: Int
    ) {
        self.host = host
        self.port = port
    }
}

/// A registered remote as returned by the device registry, flattened to one
/// row per device for `cmux remotes list`.
public struct RemoteSummary: Sendable {
    public let deviceId: String
    public let displayName: String?
    public let platform: String
    public let tag: String?
    public let routes: [RemoteRouteDisplay]
    public let lastSeen: String?
    /// True for remotes added via `cmux remotes add` (device `labels.manual`),
    /// false for a Mac's own self-registration. `cmux remotes` only lists and
    /// removes manual remotes so it never touches a self-registered device row.
    public let manual: Bool

    public init(
        deviceId: String,
        displayName: String?,
        platform: String,
        tag: String?,
        routes: [RemoteRouteDisplay],
        lastSeen: String?,
        manual: Bool
    ) {
        self.deviceId = deviceId
        self.displayName = displayName
        self.platform = platform
        self.tag = tag
        self.routes = routes
        self.lastSeen = lastSeen
        self.manual = manual
    }
}

public struct RemoteRouteDisplay: Sendable {
    public let host: String
    public let port: Int

    public init(
        host: String,
        port: Int
    ) {
        self.host = host
        self.port = port
    }
}
