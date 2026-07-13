import CmuxControlSocket
import CmuxSettings
import Foundation

extension TerminalController {
    nonisolated static func makeSocketClientCapabilityAuthority(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> SocketClientCapabilityAuthority {
        let audience = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "com.cmuxterm.app"
        let store = SocketClientCapabilitySecretStore(
            service: "\(audience).socket-client-capability"
        )
        let usesEphemeralSecret = SocketControlSettings.isDebugLikeBundleIdentifier(audience)
            || SocketControlSettings.isStagingBundleIdentifier(audience)
        let secret = usesEphemeralSecret
            ? store.makeEphemeralSecret()
            : store.loadOrCreateSecret()
        return SocketClientCapabilityAuthority(secret: secret, audience: audience)
    }

    nonisolated func socketClientCapabilityEnvironment() -> [String: String] {
        [
            SocketClientCapabilityEnvelope.environmentKey:
                socketClientCapabilityAuthority.issueCapability()
        ]
    }

    nonisolated func authorizedSocketCommand(
        _ command: String,
        peerProcessID: pid_t?,
        peerHasSameUID: Bool
    ) -> String? {
        guard socketServer.accessMode == .cmuxOnly else {
            return SocketClientCapabilityEnvelope.unwrap(command)?.command ?? command
        }
        return SocketClientAuthorization().authorizedCommand(
            command,
            peerProcessID: peerProcessID,
            peerHasSameUID: peerHasSameUID,
            capabilityAuthority: socketClientCapabilityAuthority,
            isDescendant: { isDescendant($0) }
        )
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
