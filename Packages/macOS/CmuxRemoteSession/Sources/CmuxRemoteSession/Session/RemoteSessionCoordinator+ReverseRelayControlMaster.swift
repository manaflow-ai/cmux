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
        guard let effectiveSSHOptions =
            resolvedReverseRelayControlMasterSSHOptionsLocked() else {
            return .unavailable
        }
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
        guard let effectiveSSHOptions =
            reverseRelayResolvedControlMasterSSHOptions else {
            return
        }
        guard let arguments = configuration.reverseRelayControlMasterArguments(
            controlCommand: "cancel",
            forwardSpec: forwardSpec,
            effectiveSSHOptions: effectiveSSHOptions
        ) else {
            return
        }
        _ = try? sshExec(arguments: arguments, timeout: 4)
    }

    /// Resolves cmux's `%C` template before adopting a shared master.
    ///
    /// The exact socket path is both the command target and the reset-event
    /// identity. If OpenSSH cannot produce that identity, relay startup falls
    /// back to its standalone transport without touching the unresolved
    /// master.
    private func resolvedReverseRelayControlMasterSSHOptionsLocked() -> [String]? {
        if let reverseRelayResolvedControlMasterSSHOptions {
            let sharingOptions = SSHConnectionSharingOptions()
            guard let resolvedPath = sharingOptions.cmuxOwnedControlPath(
                in: reverseRelayResolvedControlMasterSSHOptions
            ),
                  connectionBroker.retainResolvedControlMasterLease(
                      for: configuration,
                      controlPath: resolvedPath
                  ) else {
                return nil
            }
            return reverseRelayResolvedControlMasterSSHOptions
        }

        let effectiveOptions = reverseRelayControlMasterSSHOptions
        let sharingOptions = SSHConnectionSharingOptions()
        let resolver = NativeSSHControlPathResolver(
            sharingOptions: sharingOptions
        )
        guard let ownedPath = sharingOptions.cmuxOwnedControlPath(
            in: effectiveOptions
        ) else {
            reverseRelayResolvedControlMasterSSHOptions = effectiveOptions
            return effectiveOptions
        }

        let resolvedPath: String?
        if ownedPath.contains("%") {
            do {
                let result = try sshExec(
                    arguments: resolver.resolutionArguments(
                        configuration: configuration,
                        effectiveOptions: effectiveOptions
                    ),
                    timeout: 5
                )
                guard result.status == 0 else {
                    return nil
                }
                resolvedPath = resolver.resolvedControlPath(
                    effectiveOptions: effectiveOptions,
                    sshConfigOutput: result.stdout
                )
            } catch {
                debugLog(
                    "remote.relay.controlmaster.resolveFailed " +
                    "\(error.localizedDescription) \(debugConfigSummary())"
                )
                return nil
            }
        } else {
            resolvedPath = ownedPath
        }
        guard let resolvedPath else {
            debugLog(
                "remote.relay.controlmaster.resolveFailed " +
                "missing-owned-path \(debugConfigSummary())"
            )
            return nil
        }

        let resolvedOptions = resolver.replacingControlPath(
            in: effectiveOptions,
            with: resolvedPath
        )
        guard connectionBroker.retainResolvedControlMasterLease(
            for: configuration,
            controlPath: resolvedPath
        ) else {
            debugLog(
                "remote.relay.controlmaster.ownershipBusy " +
                    "\(debugConfigSummary())"
            )
            return nil
        }
        guard let observation = connectionBroker.observeControlMasterResets(
            controlPath: resolvedPath,
            handler: { [weak self] in
                self?.queue.async { [weak self] in
                    self?.sharedControlMasterDidResetLocked()
                }
            }
        ) else {
            return nil
        }
        conflictedControlMasterResetObservation = observation
        reverseRelayResolvedControlMasterSSHOptions = resolvedOptions
        return resolvedOptions
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
