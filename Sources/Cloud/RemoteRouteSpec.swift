import CMUXMobileCore
import Foundation

// Value types for `cmux remotes`: a parsed host:port attach spec and the
// flattened device-registry rows. Split from RemotesClient.swift so each file
// stays a single responsibility (pure DTOs/parsing here; the network client
// there) and under the Swift file-length budget.

/// One parsed `host:port` attach route for a manually-added remote, plus the
/// loopback decision. Pure value type so route parsing and the loopback refusal
/// are unit-testable without any network or running app.
struct RemoteRouteSpec: Equatable {
    let host: String
    let port: Int

    /// Parse a `host:port` string. Accepts bracketed IPv6 (`[::1]:51001`) and a
    /// trailing `:port`; rejects empty host, missing/out-of-range port, and
    /// loopback hosts (the same classifier the phone uses to reject a scanned
    /// loopback QR), so a remote a phone could never dial never reaches the
    /// registry.
    static func parse(_ raw: String) throws -> RemoteRouteSpec {
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
    func attachRoute(id: String, priority: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: port),
            priority: priority
        )
    }

    /// Whether a signed-in phone could authenticate to this host from the
    /// registry. Manual routes are stored as `.tailscale`, and the iOS attach
    /// path (`MobileShellRouteAuthPolicy().routeAllowsStackAuth`) only sends the
    /// Stack token over a `.tailscale` route whose host is a Tailscale address:
    /// a CGNAT `100.64.0.0/10` IP or a `*.ts.net` MagicDNS name. Any other host
    /// (LAN IP, bare hostname, Tailscale IPv6 ULA) would show in the device list
    /// but fail to connect with `insecureManualRoute`. This mirrors that policy;
    /// keep the two in sync. (`MobileShellRouteAuthPolicy` is in a mobile-only
    /// package the macOS CLI/app entry does not link, so the predicate is
    /// reimplemented here rather than imported.)
    var isTailscaleAttachable: Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // A *.ts.net MagicDNS name, but only when the whole string is a valid
        // DNS hostname (no spaces, scheme, port, or path); a loose suffix check
        // would accept undialable junk like "bad host.ts.net".
        if normalized.hasSuffix(".ts.net"), Self.isValidDNSHostname(normalized) {
            return true
        }
        // CGNAT 100.64.0.0/10: first octet 100, second octet 64...127, dotted
        // quad with all-decimal octets in 0...255.
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { part -> Int? in
            // Canonical dotted decimal only: a single "0" or no leading zero.
            // Rejects leading-zero spellings like "0100" that a libc resolver
            // would read as octal, so a route this marks Tailscale-safe can't
            // actually dial a different (non-Tailscale) address.
            guard !part.isEmpty,
                  part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part == "0" || part.first != "0",
                  let value = Int(part),
                  (0...255).contains(value) else {
                return nil
            }
            return value
        }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
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
}

/// A registered remote as returned by the device registry, flattened to one
/// row per device for `cmux remotes list`.
struct RemoteSummary {
    let deviceId: String
    let displayName: String?
    let platform: String
    let tag: String?
    let routes: [RemoteRouteDisplay]
    let lastSeen: String?
    /// True for remotes added via `cmux remotes add` (device `labels.manual`),
    /// false for a Mac's own self-registration. `cmux remotes` only lists and
    /// removes manual remotes so it never touches a self-registered device row.
    let manual: Bool
}

struct RemoteRouteDisplay {
    let host: String
    let port: Int
}
