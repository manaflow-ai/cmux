import Darwin
import Foundation

/// The single `host` + `port` the Mac pairing window offers for manual entry
/// (the "Copy IP" / "Copy Port" buttons next to the QR code).
///
/// Selection mirrors the QR's trust rules and the phone's manual-entry needs:
/// only routes a phone can actually dial qualify (loopback never does, by the
/// shared ``CmxLoopbackHost`` classifier), Tailscale routes are preferred, and
/// among them a numeric IP literal beats a MagicDNS name because a typed IP
/// works even when the phone's DNS is not pointed at the tailnet. Ties fall
/// back to the Mac's own route priority order.
public struct CmxManualPairingEntry: Equatable, Sendable {
    /// The address the user types into the phone's host field.
    public let host: String
    /// The port the user types into the phone's port field.
    public let port: Int

    /// The host value copied into the phone's manual-entry field.
    ///
    /// IPv6 endpoint hosts are stored bare in attach routes, but the iOS manual
    /// host parser requires brackets so the host/port boundary stays
    /// unambiguous.
    public var hostFieldValue: String {
        host.contains(":") && !(host.hasPrefix("[") && host.hasSuffix("]"))
            ? "[\(host)]"
            : host
    }

    /// Creates a manual-entry pair.
    /// - Parameters:
    ///   - host: The address for the phone's host field.
    ///   - port: The port for the phone's port field.
    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// The best manual-entry candidate among `routes`, or `nil` when no route
    /// is phone-dialable (no non-loopback `host:port` route at all).
    public static func best(in routes: [CmxAttachRoute]) -> CmxManualPairingEntry? {
        let candidates = routes
            .filter { !CmxLoopbackHost().matches($0) }
            .compactMap { route -> (route: CmxAttachRoute, entry: CmxManualPairingEntry)? in
                guard case let .hostPort(host, port) = route.endpoint else {
                    return nil
                }
                return (route, CmxManualPairingEntry(host: host, port: port))
            }
            .sorted { $0.route.priority < $1.route.priority }
        let preferred = candidates.filter { $0.route.kind == .tailscale }
        let pool = preferred.isEmpty ? candidates : preferred
        let pick = pool.first { isIPLiteral($0.entry.host) } ?? pool.first
        return pick?.entry
    }
}
private extension CmxManualPairingEntry {
    /// Whether `host` is a strict numeric IP literal (dotted-quad IPv4 or any
    /// IPv6 spelling). Used only as a preference signal, not a trust boundary.
    static func isIPLiteral(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            return true
        }
        var ipv6 = in6_addr()
        return inet_pton(AF_INET6, host, &ipv6) == 1
    }
}
