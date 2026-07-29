internal import CmuxCore
internal import CmuxFoundation
internal import Foundation

/// Result of trying to install a relay channel on an existing SSH master.
enum ReverseRelayControlMasterStartOutcome: Sendable {
    case started
    case unavailable
    case bindingConflict(String)
}

extension RemoteSessionCoordinator {
    /// Matches the connection-sharing defaults used by foreground authentication.
    var reverseRelayControlMasterSSHOptions: [String] {
        SSHConnectionSharingOptions().mergingDefaults(
            into: configuration.sshOptions
        )
    }

    /// Prefers the already-authenticated shared transport without creating one.
    func startReverseRelayViaControlMasterLocked(
        forwardSpec: String,
        relayPort: Int
    ) -> ReverseRelayControlMasterStartOutcome {
        let effectiveSSHOptions = reverseRelayControlMasterSSHOptions
        guard let arguments = configuration.reverseRelayControlMasterArguments(
            controlCommand: "forward",
            forwardSpec: forwardSpec,
            effectiveSSHOptions: effectiveSSHOptions
        ) else {
            return .unavailable
        }

        do {
            let result = try sshExec(arguments: arguments, timeout: 6)
            guard result.status == 0 else {
                let detail = Self.bestErrorLine(
                    stderr: result.stderr,
                    stdout: result.stdout
                ) ?? "ssh exited \(result.status)"
                debugLog(
                    "remote.relay.controlmaster.forwardFailed \(detail) " +
                    debugConfigSummary()
                )
                if Self.isReverseRelayPortBindingFailure(
                    detail,
                    relayPort: relayPort
                ) {
                    return .bindingConflict(detail)
                }
                return .unavailable
            }
            reverseRelayControlMasterForwardSpec = forwardSpec
            return .started
        } catch {
            debugLog(
                "remote.relay.controlmaster.forwardFailed " +
                "\(error.localizedDescription) \(debugConfigSummary())"
            )
            return .unavailable
        }
    }

    /// Cancels only the exact forward this coordinator successfully installed.
    func stopReverseRelayViaControlMasterLocked() {
        guard let forwardSpec = reverseRelayControlMasterForwardSpec else { return }
        reverseRelayControlMasterForwardSpec = nil
        let effectiveSSHOptions = reverseRelayControlMasterSSHOptions
        guard let arguments = configuration.reverseRelayControlMasterArguments(
            controlCommand: "cancel",
            forwardSpec: forwardSpec,
            effectiveSSHOptions: effectiveSSHOptions
        ) else {
            return
        }
        _ = try? sshExec(arguments: arguments, timeout: 4)
    }
}
