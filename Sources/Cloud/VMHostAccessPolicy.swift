import Foundation

/// What a Cloud VM may ask of this Mac over the private-network listener,
/// and how a caller proves it is one of the user's own machines.
///
/// The listener is reachable only through the user's WireGuard tunnel into
/// their private Cloud VM network (`VMHostListenerCoordinator`), so the peers
/// that can reach it at all are the user's machines and the user's other
/// tunnels. This policy narrows that further:
///
/// - the peer address must sit inside the network's own CIDRs,
/// - every request must carry the per-machine token this Mac minted and
///   delivered to that machine (`VMHostTokenStore`),
/// - only the telemetry and attention verbs below are admitted, and every
///   workspace or surface selector in a request must belong to a workspace
///   bound to the calling machine (`workspace.cloud_vm_bind`).
///
/// Nothing here types, focuses, navigates, reads Mac state, or reaches the
/// cloud control plane. A compromised guest can spam its own owner's
/// notifications and nothing else.
enum VMHostAccessPolicy {
    /// Request parameter carrying the machine token. Stripped before dispatch.
    static let tokenParamKey = "_cmux_vm_host_token"

    /// Longest request line the listener buffers before dropping the client.
    /// Hook payloads are small; agents in a guest run arbitrary code, so the
    /// cap is deliberately far below the local socket's limit.
    static let maxRequestLineBytes = 64 * 1024

    /// Verbs a machine may call. Fire-and-forget telemetry and attention, plus
    /// the Feed bridge (`feed.push`) which holds the request for the human's
    /// decision. Mirrors the ssh remote relay's allow-list minus everything
    /// that reads Mac state or has nothing to do without an ssh channel.
    static let allowedMethods: Set<String> = [
        "system.ping",
        "system.capabilities",
        "notification.create",
        "notification.create_for_target",
        "agent.resolve_delivery_target",
        "surface.report_tty",
        "surface.report_pwd",
        "surface.report_git_branch",
        "surface.clear_git_branch",
        "surface.report_shell_state",
        "workspace.set_auto_title",
        "workspace.status.set",
        "feed.push",
    ]

    /// Verbs that must name a workspace explicitly. A machine never lands on
    /// whatever the user happens to be looking at.
    static let workspaceRequiredMethods: Set<String> = [
        "notification.create",
        "notification.create_for_target",
        "surface.report_tty",
        "surface.report_pwd",
        "surface.report_git_branch",
        "surface.clear_git_branch",
        "surface.report_shell_state",
        "workspace.set_auto_title",
        "workspace.status.set",
        "feed.push",
    ]

    /// Verbs that must also name a surface.
    static let surfaceRequiredMethods: Set<String> = [
        "notification.create_for_target",
        "surface.report_tty",
        "surface.report_pwd",
        "surface.report_git_branch",
        "surface.clear_git_branch",
        "surface.report_shell_state",
    ]

    // MARK: - Source addresses

    /// Whether `peer` (a numeric IPv4 or IPv6 address) lies inside any of the
    /// network CIDRs. IPv4-mapped IPv6 peers (`::ffff:10.1.2.3`) are compared
    /// as IPv4. Anything unparsable is denied.
    static func sourceIsAllowed(peer: String, networkCIDRs: [String]) -> Bool {
        guard let peerBytes = addressBytes(peer) else { return false }
        for cidr in networkCIDRs {
            guard let (network, prefix) = parseCIDR(cidr), network.count == peerBytes.count else { continue }
            if matches(peerBytes, network: network, prefixLength: prefix) { return true }
        }
        return false
    }

    /// `"10.16.0.0/24"` → (address bytes, prefix length). A bare address is a
    /// full-length prefix.
    static func parseCIDR(_ cidr: String) -> ([UInt8], Int)? {
        let trimmed = cidr.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        guard let first = parts.first, let bytes = addressBytes(first) else { return nil }
        let maxPrefix = bytes.count * 8
        guard parts.count == 2 else { return (bytes, maxPrefix) }
        guard let prefix = Int(parts[1]), (0...maxPrefix).contains(prefix) else { return nil }
        return (bytes, prefix)
    }

    /// Numeric address → raw bytes (4 for IPv4, 16 for IPv6). IPv4-mapped
    /// IPv6 collapses to its 4 IPv4 bytes so one CIDR list covers both socket
    /// families. Zone suffixes (`fe80::1%utun4`) are dropped before parsing.
    static func addressBytes(_ address: String) -> [UInt8]? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let zone = text.firstIndex(of: "%") { text = String(text[..<zone]) }
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            return withUnsafeBytes(of: &v4.s_addr) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            // ::ffff:a.b.c.d
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return Array(bytes[12..<16])
            }
            return bytes
        }
        return nil
    }

    private static func matches(_ address: [UInt8], network: [UInt8], prefixLength: Int) -> Bool {
        var remaining = prefixLength
        for index in 0..<address.count {
            if remaining <= 0 { return true }
            let bits = min(8, remaining)
            let mask: UInt8 = bits == 8 ? 0xff : UInt8(0xff << (8 - bits) & 0xff)
            if (address[index] & mask) != (network[index] & mask) { return false }
            remaining -= bits
        }
        return true
    }

    // MARK: - Tokens

    /// Constant-time equality for tokens. Length differences still return
    /// false, but through the same number of byte comparisons.
    static func tokensMatch(_ presented: String, _ expected: String) -> Bool {
        let a = Array(presented.utf8)
        let b = Array(expected.utf8)
        var difference: UInt8 = a.count == b.count ? 0 : 1
        let length = max(a.count, b.count)
        for index in 0..<length {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            difference |= x ^ y
        }
        return difference == 0
    }
}
