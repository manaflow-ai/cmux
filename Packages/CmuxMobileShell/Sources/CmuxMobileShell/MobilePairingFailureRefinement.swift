internal import CMUXMobileCore
import Foundation

/// What this device currently knows about its own Tailscale tailnet, used to
/// refine reachability failures into the explicit ``MobilePairingFailureCategory/tailscaleOff(host:port:)``
/// walk-through.
///
/// This is the seam for the Tailscale-status detector
/// (https://github.com/manaflow-ai/cmux/pull/5722, `TailscaleStatusMonitor` in
/// `CmuxMobileTransport`): its `TailscaleStatus` cases map 1:1 onto these. The
/// composite reads its injected ``MobileShellComposite/tailnetHintProvider`` at
/// classification time, so wiring the detector is one line at the composition
/// root. Until it is wired, the default ``unknown`` makes refinement a no-op.
public enum MobilePairingTailnetHint: Equatable, Sendable {
    /// A tunnel interface currently holds a tailnet self-address.
    case active
    /// No tailnet address found. iOS cannot distinguish "Tailscale is not
    /// installed" from "installed but switched off"; both land here.
    case inactiveOrNotInstalled
    /// No claim either way (detector not wired, or interface enumeration failed).
    case unknown
}

extension MobilePairingFailureCategory {
    /// The single mapping from a pairing-code decode failure (thrown by
    /// `CmxAttachTicketInput.decode`) to a category, mirroring
    /// ``classify(error:route:)`` for the validation phase. Order matters: the
    /// typed format/version and expiry errors come first so they cannot collapse
    /// into the generic ``invalidCode``.
    public static func classify(decodeError error: any Error) -> MobilePairingFailureCategory {
        if let payloadError = error as? MobileSyncPairingPayloadError {
            switch payloadError {
            case let .unsupportedVersion(version):
                return version > MobileSyncPairingPayload.currentVersion ? .codeFromNewerApp : .codeFromOlderMac
            case .unsupportedPayloadFormat:
                // A grammar this build cannot read at all is by definition newer
                // than this build (older grammars stay decodable forever).
                return .codeFromNewerApp
            case .expired:
                return .ticketExpired
            case .emptyHost, .invalidPort, .forbiddenSecretField, .invalidURL, .invalidPayloadEncoding:
                return .invalidCode
            }
        }
        if let ticketError = error as? CmxAttachTicketError {
            switch ticketError {
            case let .unsupportedVersion(version):
                return version > CmxAttachTicket.currentVersion ? .codeFromNewerApp : .codeFromOlderMac
            case .expired:
                return .ticketExpired
            case .noRoutes, .emptyAuthToken:
                return .invalidCode
            }
        }
        return .invalidCode
    }

    /// Upgrades a reachability failure on a Tailscale-shaped address to the
    /// explicit ``tailscaleOff(host:port:)`` walk-through when this device's
    /// tailnet is known to be inactive.
    ///
    /// Only the three categories whose dominant real-world cause is "the
    /// tailnet address is simply unroutable" are upgraded (`hostUnreachable`,
    /// `dnsFailed`, `handshakeTimedOut`), and only when the failed host looks
    /// like a tailnet address (CGNAT 100.64.0.0/10, the Tailscale IPv6 ULA, or
    /// a `.ts.net` MagicDNS name). Every other category, hint, and host shape
    /// passes through unchanged, so an `unknown` hint makes this a no-op.
    public func refined(tailnetHint: MobilePairingTailnetHint) -> MobilePairingFailureCategory {
        guard tailnetHint == .inactiveOrNotInstalled else { return self }
        switch self {
        case let .hostUnreachable(host, port),
             let .dnsFailed(host, port),
             let .handshakeTimedOut(host, port):
            guard let host, Self.isTailnetShapedHost(host) else { return self }
            return .tailscaleOff(host: host, port: port)
        default:
            return self
        }
    }

    /// Whether `host` looks like a Tailscale address: a `.ts.net` MagicDNS
    /// name, an IPv4 in the Tailscale CGNAT range `100.64.0.0/10`, or an IPv6
    /// in the Tailscale ULA `fd7a:115c:a1e0::/48`.
    static func isTailnetShapedHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: .whitespaces)
        if normalized.hasSuffix(".ts.net") {
            return true
        }
        if normalized.hasPrefix("fd7a:115c:a1e0") {
            return true
        }
        let octets = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let first = UInt8(octets[0]),
              let second = UInt8(octets[1]),
              UInt8(octets[2]) != nil,
              UInt8(octets[3]) != nil else {
            return false
        }
        // 100.64.0.0/10: first octet 100, second octet's top two bits are 01.
        return first == 100 && (64...127).contains(second)
    }
}
