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
                let bindingConflict = [
                    result.stderr,
                    result.stdout,
                ].compactMap {
                    Self.reverseRelayPortBindingFailureLine(
                        in: $0,
                        relayPort: relayPort
                    )
                }.first
                let detail = Self.bestErrorLine(
                    stderr: result.stderr,
                    stdout: result.stdout
                ) ?? "ssh exited \(result.status)"
                debugLog(
                    "remote.relay.controlmaster.forwardFailed \(detail) " +
                    debugConfigSummary()
                )
                if let bindingConflict {
                    return .bindingConflict(bindingConflict)
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

    /// Invalidates a relay installed on a shared master that another owner
    /// exited during conflict recovery.
    func sharedControlMasterDidResetLocked() {
        guard reverseRelayControlMasterForwardSpec != nil else { return }
        reverseRelayControlMasterForwardSpec = nil
        debugLog(
            "remote.relay.controlmaster.resetObserved \(debugConfigSummary())"
        )
        guard !isStopping,
              daemonReady,
              let remotePath = daemonRemotePath,
              !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
    }
}
