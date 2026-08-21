import CmuxControlSocket
import Foundation

/// Issues and verifies persistent, bundle-scoped capabilities for local-only
/// mobile pairing. A capability is useful only together with the exact
/// Tailscale endpoint carried by its pairing code.
struct MobileLocalPairingAuthority: Sendable {
    private let authority: SocketClientCapabilityAuthority

    init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        let normalizedBundleIdentifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let audience: String
        if let normalizedBundleIdentifier,
           !normalizedBundleIdentifier.isEmpty {
            audience = normalizedBundleIdentifier
        } else {
            audience = "com.cmuxterm.app"
        }
        let store = SocketClientCapabilitySecretStore(
            service: "\(audience).mobile-local-pairing-capability.v1"
        )
        authority = SocketClientCapabilityAuthority(
            secret: store.loadOrCreateSecret(),
            audience: "\(audience).mobile-local-pairing"
        )
    }

    func issueCapability() -> String {
        authority.issueCapability()
    }

    func verifies(_ capability: String?) -> Bool {
        guard let capability = capability?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !capability.isEmpty else { return false }
        return authority.verifies(capability)
    }
}
