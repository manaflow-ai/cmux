internal import CmuxCore
internal import CmuxFoundation
internal import Foundation

/// Result of trying to install a relay channel on an existing SSH master.
enum ReverseRelayControlMasterStartOutcome: Sendable {
    case started
    case unavailable
    case bindingConflict(String, controlPath: String?)
}

extension RemoteSessionCoordinator {
    /// Matches the connection-sharing defaults used by foreground authentication.
    var reverseRelayControlMasterSSHOptions: [String] {
        connectionBroker.sharingOptions.mergingDefaults(
            into: configuration.sshOptions
        )
    }

    /// Claims the exact cmux-owned socket before background SSH can reuse it.
    func prepareControlMasterOwnershipLocked() throws {
        guard configuration.transport != .ssh ||
                resolvedControlMasterSSHOptionsLocked() != nil else {
            throw NSError(
                domain: "cmux.remote.control-master",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        strings.controlMasterOwnershipUnavailable,
                ]
            )
        }
    }

    /// Prefers the already-authenticated shared transport without creating one.
    func startReverseRelayViaControlMasterLocked(
        forwardSpec: String,
        relayPort: Int
    ) -> ReverseRelayControlMasterStartOutcome {
        guard let effectiveSSHOptions =
            resolvedControlMasterSSHOptionsLocked() else {
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
                    let ownedControlPath =
                        connectionBroker.sharingOptions
                        .cmuxOwnedControlPath(
                            in: effectiveSSHOptions
                        )
                    let resolvedControlPath =
                        ownedControlPath?.contains("%") == false
                        ? ownedControlPath
                        : nil
                    return .bindingConflict(
                        bindingConflict,
                        controlPath: resolvedControlPath
                    )
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
            resolvedControlMasterSSHOptions else {
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

    /// Resolves cmux's `%C` template before any background SSH command can
    /// adopt the shared master.
    ///
    /// The exact socket path is both the process-ownership lease and recovery
    /// identity. Custom paths remain user-managed. An unresolved cmux template
    /// is intentionally returned unchanged: OpenSSH expands `%C` as part of
    /// the real control operation, so a speculative `ssh -G` must not delay a
    /// healthy connection. Recovery resolves the path lazily only after a
    /// forward-binding conflict, when the exact identity is required for a
    /// destructive `ssh -O exit`.
    func resolvedControlMasterSSHOptionsLocked() -> [String]? {
        if let resolvedControlMasterSSHOptions {
            let sharingOptions = connectionBroker.sharingOptions
            guard let resolvedPath = sharingOptions.cmuxOwnedControlPath(
                in: resolvedControlMasterSSHOptions
            ) else {
                return resolvedControlMasterSSHOptions
            }
            guard !resolvedPath.contains("%") else {
                return resolvedControlMasterSSHOptions
            }
            guard connectionBroker.retainResolvedControlMasterLease(
                for: configuration,
                controlPath: resolvedPath
            ) else {
                return nil
            }
            observeControlMasterReapsLocked(
                controlPath: resolvedPath
            )
            return resolvedControlMasterSSHOptions
        }

        let effectiveOptions = reverseRelayControlMasterSSHOptions
        let sharingOptions = connectionBroker.sharingOptions
        let resolver = NativeSSHControlPathResolver(
            sharingOptions: sharingOptions
        )
        guard let ownedPath = sharingOptions.cmuxOwnedControlPath(
            in: effectiveOptions
        ) else {
            resolvedControlMasterSSHOptions = effectiveOptions
            return effectiveOptions
        }

        guard !ownedPath.contains("%") else {
            // OpenSSH expands `%C` while executing `ssh -O forward`; resolving
            // it speculatively here adds a second local process before the
            // first remote bootstrap command and can consume the full probe
            // timeout on a slow or unusual ssh_config.
            resolvedControlMasterSSHOptions = effectiveOptions
            return effectiveOptions
        }

        let resolvedOptions = resolver.replacingControlPath(
            in: effectiveOptions,
            with: ownedPath
        )
        guard connectionBroker.retainResolvedControlMasterLease(
            for: configuration,
            controlPath: ownedPath
        ) else {
            debugLog(
                "remote.relay.controlmaster.ownershipBusy " +
                    "\(debugConfigSummary())"
            )
            return nil
        }
        observeControlMasterReapsLocked(controlPath: ownedPath)
        resolvedControlMasterSSHOptions = resolvedOptions
        return resolvedOptions
    }

}
