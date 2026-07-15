import CmuxControlSocket
import CmuxSettings
import Foundation

extension TerminalController {
    private nonisolated static var socketClientPreauthorizationLimits: ControlClientLineReadLimits {
        ControlClientLineReadLimits(
            maximumBytes: 4 * 1024 * 1024,
            timeoutMilliseconds: 2_000
        )
    }

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

    /// Bounds every cmux-only peer until its first command can choose capability
    /// or ancestry authorization without a speculative process-tree walk.
    nonisolated func socketClientInitialReadLimits() -> ControlClientLineReadLimits? {
        guard socketServer.accessMode == .cmuxOnly else { return nil }
        return Self.socketClientPreauthorizationLimits
    }

    nonisolated func authorizedSocketCommand(
        _ command: String,
        peerProcessID: pid_t?,
        peerHasSameUID: Bool,
        authorization: inout SocketClientAuthorization
    ) -> String? {
        guard socketServer.accessMode == .cmuxOnly else {
            return SocketClientCapabilityCommand(command)?.command ?? command
        }
        return authorization.authorizedCommand(
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
