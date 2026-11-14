import Foundation

/// Where a web link tapped on this iPhone opens. A public page (github.com, a doc, a PR)
/// opens here, on the phone: the person is on the phone, and signing in, passkeys and their
/// own accounts are here. Only a page the Mac serves itself or reaches on its own network
/// (a dev server on `localhost`, a LAN or tailnet address, a `.local` or single-label host)
/// opens in a cmux browser tab on the Mac, beside the terminal, where it can load.
public enum WebLinkPlace: Equatable, Sendable {
    case phone
    case mac

    public init(_ url: URL) {
        self = Self.isMacLocal(url) ? .mac : .phone
    }

    /// The link names a host only the Mac (or its network) can reach.
    public static func isMacLocal(_ url: URL) -> Bool {
        guard let raw = url.host(percentEncoded: false)?.lowercased(), !raw.isEmpty else { return false }
        let host = raw.hasSuffix(".") ? String(raw.dropLast()) : raw
        if let v4 = ipv4(host) { return isLocal(v4) }
        if host.contains(":") { return isLocalIPv6(host) }
        // A bare name (`devbox`, `localhost`) resolves on the Mac's network, never the internet.
        if !host.contains(".") { return true }
        return localSuffixes.contains { host.hasSuffix($0) }
    }

    /// Names that resolve only on a machine or its network (RFC 6761, 6762, 8375; tailnets).
    static let localSuffixes = [".localhost", ".local", ".lan", ".home.arpa", ".internal", ".ts.net", ".test"]

    static func ipv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { UInt8($0) }
        return bytes.count == 4 ? bytes : nil
    }

    static func isLocal(_ a: [UInt8]) -> Bool {
        switch (a[0], a[1]) {
        case (0, _), (10, _), (127, _): true
        case (169, 254), (192, 168): true
        case (172, 16...31): true
        case (100, 64...127): true // CGNAT, Tailscale's 100.x addresses
        default: false
        }
    }

    static func isLocalIPv6(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "::1" || h == "::" { return true }
        if h.hasPrefix("::ffff:"), let v4 = ipv4(String(h.dropFirst(7))) { return isLocal(v4) }
        // fc00::/7 (unique local, Tailscale's fd7a:), fe80::/10 (link local).
        return h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe8") || h.hasPrefix("fe9")
            || h.hasPrefix("fea") || h.hasPrefix("feb")
    }
}
