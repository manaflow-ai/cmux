public import Foundation

/// The disclosure boundary applied before serializing attach routes.
public enum CmxAttachRouteDisclosure: Equatable, Sendable {
    /// Same-account registry, presence, or local persistence.
    case authenticated
    /// Cloud rendezvous shared with other authenticated devices.
    case cloudRendezvous
    /// An unauthenticated network status response.
    case publicStatus
    /// A scannable pairing payload.
    case pairingQRCode
    /// The paired-Mac server backup, sharing the cloud rendezvous boundary.
    case pairedMacCloudBackup
}

extension CmxAttachRoute {
    /// Returns the route shape permitted at a serialization boundary.
    ///
    /// Unauthenticated status exposes no attach routes. The surviving
    /// endpoint shapes (host/port and URL) carry no redactable metadata, so
    /// every authenticated boundary discloses the route unchanged.
    public func disclosed(
        for disclosure: CmxAttachRouteDisclosure,
        at now: Date
    ) -> Self? {
        if disclosure == .publicStatus {
            return nil
        }
        return self
    }
}

extension CmxAttachTicket {
    /// Returns a ticket whose routes are safe for an authenticated transport.
    ///
    /// Pairing QR and public-status payloads intentionally have different
    /// field-level disclosure rules, so they must not use this copy operation.
    public func authenticatedDisclosure(at now: Date) throws -> Self {
        try Self(
            version: version,
            workspaceID: workspaceID,
            terminalID: terminalID,
            macDeviceID: macDeviceID,
            macDisplayName: macDisplayName,
            macUserEmail: macUserEmail,
            macUserID: macUserID,
            macPairingCompatibilityVersion: macPairingCompatibilityVersion,
            macAppVersion: macAppVersion,
            macAppBuild: macAppBuild,
            routes: routes.compactMap {
                $0.disclosed(for: .authenticated, at: now)
            },
            expiresAt: expiresAt,
            authToken: authToken
        )
    }
}
