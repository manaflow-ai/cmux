import Foundation

/// Invalid input for a user-entered Tailscale compatibility pairing code.
public enum CmxUserTailscalePairingAuthorizationError: Error, Equatable, Sendable {
    /// The host was not a numeric Tailscale peer address.
    case invalidHost
    /// The port fell outside `1...65535`.
    case invalidPort(Int)
}

/// A narrow capability allowing one user-entered Tailscale compatibility code
/// to dial the exact peer address it named.
///
/// The authorization event is the user reading the code off their Mac's
/// pairing window (QR scan or pasted text) in this app session. Unlike
/// ``CmxLegacyTailscaleAuthorizationEvidence`` there is no Mac device binding:
/// any identity a code claims is self-reported and carries no authority, so
/// this value anchors on the exact destination alone and never persists. Once
/// the host authenticates, the shell records a device-bound grant and later
/// dials use the evidence path.
public struct CmxUserTailscalePairingAuthorization: Equatable, Sendable {
    /// The canonical numeric Tailscale peer address from the entered code.
    public let host: String
    /// The exact legacy mobile listener port from the entered code.
    public let port: Int

    /// Validates and canonicalizes one user-entered compatibility destination.
    public init(host: String, port: Int) throws {
        guard let peerAddress = CmxTailscalePeerAddress(host) else {
            throw CmxUserTailscalePairingAuthorizationError.invalidHost
        }
        guard (1 ... 65_535).contains(port) else {
            throw CmxUserTailscalePairingAuthorizationError.invalidPort(port)
        }
        self.host = peerAddress.value
        self.port = port
    }

    /// Whether a dial still names the exact peer the user entered.
    public func authorizes(host: String, port: Int) -> Bool {
        guard let peerAddress = CmxTailscalePeerAddress(host) else {
            return false
        }
        return peerAddress.value == self.host && port == self.port
    }
}
