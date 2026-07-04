import Darwin
import Foundation

/// The single `host:port` address the Mac pairing window offers for manual
/// entry (the "Copy Address" button next to the QR code) and the phone's
/// address box parses back.
///
/// Selection mirrors the QR's trust rules and the phone's manual-entry needs:
/// only routes a phone can actually dial qualify (loopback never does, by the
/// shared ``CmxLoopbackHost`` classifier), Tailscale routes are preferred, and
/// among them a numeric IP literal beats a MagicDNS name because a typed IP
/// works even when the phone's DNS is not pointed at the tailnet. Ties fall
/// back to the Mac's own route priority order.
public struct CmxManualPairingEntry: Equatable, Sendable {
    /// The bare host part of the address (no brackets, no port).
    public let host: String
    /// The port part of the address.
    public let port: Int

    /// The one-string `host:port` form the Mac copies and the phone pastes.
    /// IPv6 hosts are bracketed (`[fe80::1]:58465`) so the port separator
    /// stays unambiguous.
    public var displayString: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Creates a manual-entry pair.
    /// - Parameters:
    ///   - host: The bare host part of the address.
    ///   - port: The port part of the address.
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

    /// Splits a user-entered address into host + port, inverting
    /// ``displayString``: accepts `host`, `host:port`, `[v6]`, `[v6]:port`,
    /// and a bare bracketless IPv6 literal (two or more colons, which can
    /// never be a `host:port` split, so the whole string is the host).
    ///
    /// Only the shape is decided here; host *validity* (no schemes, paths,
    /// or whitespace) stays with the caller's host policy. Returns `nil`
    /// when an explicit port separator is present but the port is not a
    /// number in `1...65535`, or when a bracket form is malformed.
    /// - Parameters:
    ///   - input: The raw address string the user typed or pasted.
    ///   - defaultPort: The port used when `input` has no port suffix.
    public static func parse(_ input: String, defaultPort: Int) -> CmxManualPairingEntry? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.hasPrefix("[") {
            guard let closing = trimmed.firstIndex(of: "]") else {
                return nil
            }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            let remainder = trimmed[trimmed.index(after: closing)...]
            guard !host.isEmpty else {
                return nil
            }
            if remainder.isEmpty {
                return CmxManualPairingEntry(host: host, port: defaultPort)
            }
            guard remainder.hasPrefix(":"), let port = validPort(remainder.dropFirst()) else {
                return nil
            }
            return CmxManualPairingEntry(host: host, port: port)
        }

        let colonCount = trimmed.filter { $0 == ":" }.count
        switch colonCount {
        case 0:
            return CmxManualPairingEntry(host: trimmed, port: defaultPort)
        case 1:
            let separator = trimmed.firstIndex(of: ":")!
            let host = String(trimmed[..<separator])
            guard !host.isEmpty, let port = validPort(trimmed[trimmed.index(after: separator)...]) else {
                return nil
            }
            return CmxManualPairingEntry(host: host, port: port)
        default:
            // Bracketless IPv6 literal; there is no unambiguous port split.
            return CmxManualPairingEntry(host: trimmed, port: defaultPort)
        }
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

    /// Parses a port substring, requiring all digits and the 1...65535 range.
    static func validPort(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let port = Int(text),
              (1...65535).contains(port) else {
            return nil
        }
        return port
    }
}
