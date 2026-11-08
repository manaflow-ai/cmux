import Foundation

/// Invalid input for a persisted pre-Iroh Tailscale compatibility grant.
public enum CmxLegacyTailscaleAuthorizationEvidenceError: Error, Equatable, Sendable {
    /// The Mac device identifier was empty or surrounded by whitespace.
    case invalidMacDeviceID
    /// The host was not a numeric Tailscale peer address.
    case invalidHost
    /// The port fell outside `1...65535`.
    case invalidPort(Int)
}

/// A narrow capability allowing one pre-Iroh pairing to keep using its exact
/// plaintext Tailscale route while both sides move through a staggered update.
///
/// This value is transport evidence, not route discovery. It authorizes only
/// one canonical Mac device ID, numeric Tailscale peer address, and TCP port.
public struct CmxLegacyTailscaleAuthorizationEvidence: Equatable, Sendable {
    /// The canonical paired Mac device identifier.
    public let macDeviceID: String
    /// The canonical numeric Tailscale peer address.
    public let host: String
    /// The exact legacy mobile listener port.
    public let port: Int

    /// Validates and canonicalizes one persisted compatibility grant.
    public init(macDeviceID: String, host: String, port: Int) throws {
        let trimmedDeviceID = macDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDeviceID.isEmpty, trimmedDeviceID == macDeviceID else {
            throw CmxLegacyTailscaleAuthorizationEvidenceError.invalidMacDeviceID
        }
        guard let peerAddress = CmxTailscalePeerAddress(host) else {
            throw CmxLegacyTailscaleAuthorizationEvidenceError.invalidHost
        }
        guard (1 ... 65_535).contains(port) else {
            throw CmxLegacyTailscaleAuthorizationEvidenceError.invalidPort(port)
        }

        self.macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        self.host = peerAddress.value
        self.port = port
    }

    /// Whether a request still names the exact peer captured by this grant.
    public func authorizes(macDeviceID: String?, host: String, port: Int) -> Bool {
        guard let macDeviceID,
              cmxCanonicalDeviceID(macDeviceID) == self.macDeviceID,
              let peerAddress = CmxTailscalePeerAddress(host) else {
            return false
        }
        return peerAddress.value == self.host && port == self.port
    }
}
