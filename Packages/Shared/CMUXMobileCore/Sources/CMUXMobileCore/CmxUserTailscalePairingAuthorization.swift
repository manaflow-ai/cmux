import Foundation

/// Invalid input for a user-entered compatibility pairing destination.
public enum CmxUserTailscalePairingAuthorizationError: Error, Equatable, Sendable {
    /// The host was not a valid DNS name or IP address.
    case invalidHost
    /// The port fell outside `1...65535`.
    case invalidPort(Int)
}

/// A narrow capability allowing one user-entered Tailscale compatibility code
/// to dial the exact host and port it named.
///
/// The authorization event is the user reading a code from their Mac or
/// explicitly entering its destination in this app session. Unlike
/// ``CmxLegacyTailscaleAuthorizationEvidence`` there is no Mac device binding:
/// any identity a code claims is self-reported and carries no authority, so
/// this value anchors on the exact destination alone and never persists. Numeric
/// Tailscale addresses receive interface-bound transport proof. A MagicDNS name,
/// private-LAN address, or other explicitly entered host uses the existing
/// manual-host trust warning and remains exact-destination-only. Once the host
/// authenticates, the shell records a device-local grant and later dials use that
/// grant.
public struct CmxUserTailscalePairingAuthorization: Equatable, Sendable {
    /// The canonical host from the entered code.
    public let host: String
    /// The exact legacy mobile listener port from the entered code.
    public let port: Int

    /// Validates and canonicalizes one user-entered compatibility destination.
    public init(host: String, port: Int) throws {
        guard let normalizedHost = Self.normalizedHost(host) else {
            throw CmxUserTailscalePairingAuthorizationError.invalidHost
        }
        guard (1 ... 65_535).contains(port) else {
            throw CmxUserTailscalePairingAuthorizationError.invalidPort(port)
        }
        self.host = normalizedHost
        self.port = port
    }

    /// Whether a dial still names the exact peer the user entered.
    public func authorizes(host: String, port: Int) -> Bool {
        guard let normalizedHost = Self.normalizedHost(host) else {
            return false
        }
        return normalizedHost == self.host && port == self.port
    }

    private static func normalizedHost(_ rawHost: String) -> String? {
        if let peerAddress = CmxTailscalePeerAddress(rawHost) {
            return peerAddress.value
        }
        guard let manualHost = CmxManualHost(rawHost)?.rawValue,
              !CmxLoopbackHost().matches(manualHost) else {
            return nil
        }
        return manualHost
    }
}
