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
                    if recoverInheritedReverseForwardLocked(
                        forwardSpec: forwardSpec,
                        relayPort: relayPort,
                        effectiveSSHOptions: effectiveSSHOptions
                    ) {
                        reverseRelayControlMasterForwardSpec =
                            forwardSpec
                        return .started
                    }
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

    /// Cancels only a forward whose persisted relay identity matches this workspace.
    ///
    /// A bind diagnostic alone is ambiguous: an unrelated remote process may
    /// own the port. Recovery therefore requires the exact cmux-owned
    /// ControlPath, cross-process exclusive ownership, matching relay metadata,
    /// and a successful OpenSSH `cancel` for the listen address before retrying.
    private func recoverInheritedReverseForwardLocked(
        forwardSpec: String,
        relayPort: Int,
        effectiveSSHOptions: [String]
    ) -> Bool {
        guard reverseRelayControlMasterForwardSpec == nil,
              let relayID = configuration.relayID?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              !relayID.isEmpty,
              let relayToken = configuration.relayToken?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              !relayToken.isEmpty,
              let controlPath =
              connectionBroker.sharingOptions.cmuxOwnedControlPath(
                  in: effectiveSSHOptions
              ),
              !controlPath.contains("%"),
              let authorization =
              connectionBroker.beginReverseForwardRecovery(
                  controlPath: controlPath
              ) else {
            return false
        }
        defer { authorization.release() }

        let probeScript = Self.remoteRelayMetadataOwnershipProbeScript(
            relayPort: relayPort,
            relayID: relayID,
            relayToken: relayToken,
            persistentDaemonSlot: configuration.persistentDaemonSlot
        )
        let probeCommand = "sh -c \(probeScript.shellSingleQuoted)"
        do {
            let probe = try sshExec(
                arguments: configuration.batchSSHCommandArguments(
                    command: probeCommand,
                    effectiveSSHOptions: effectiveSSHOptions
                ),
                timeout: 6
            )
            guard probe.status == 0 else {
                debugLog(
                    "remote.relay.inheritedForward.recoveryIgnored " +
                    "reason=metadata-mismatch relayPort=\(relayPort) " +
                    debugConfigSummary()
                )
                return false
            }

            let listenSpec = "127.0.0.1:\(relayPort)"
            guard let cancelArguments =
                configuration.reverseRelayControlMasterArguments(
                    controlCommand: "cancel",
                    forwardSpec: listenSpec,
                    effectiveSSHOptions: effectiveSSHOptions
                ) else {
                return false
            }
            let cancellation = try sshExec(
                arguments: cancelArguments,
                timeout: 4
            )
            guard cancellation.status == 0 else {
                debugLog(
                    "remote.relay.inheritedForward.recoveryIgnored " +
                    "reason=forward-not-owned relayPort=\(relayPort) " +
                    debugConfigSummary()
                )
                return false
            }

            guard let forwardArguments =
                configuration.reverseRelayControlMasterArguments(
                    controlCommand: "forward",
                    forwardSpec: forwardSpec,
                    effectiveSSHOptions: effectiveSSHOptions
                ) else {
                return false
            }
            let retry = try sshExec(
                arguments: forwardArguments,
                timeout: 6
            )
            guard retry.status == 0 else {
                debugLog(
                    "remote.relay.inheritedForward.retryFailed " +
                    "relayPort=\(relayPort) \(debugConfigSummary())"
                )
                return false
            }
            debugLog(
                "remote.relay.inheritedForward.recovered " +
                "relayPort=\(relayPort) \(debugConfigSummary())"
            )
            return true
        } catch {
            debugLog(
                "remote.relay.inheritedForward.recoveryIgnored " +
                "relayPort=\(relayPort) \(error.localizedDescription) " +
                debugConfigSummary()
            )
            return false
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
    /// identity. Custom paths remain user-managed. If OpenSSH cannot resolve a
    /// cmux-owned path, the connection attempt fails before daemon bootstrap.
    func resolvedControlMasterSSHOptionsLocked() -> [String]? {
        if let resolvedControlMasterSSHOptions {
            let sharingOptions = connectionBroker.sharingOptions
            guard let resolvedPath = sharingOptions.cmuxOwnedControlPath(
                in: resolvedControlMasterSSHOptions
            ) else {
                return resolvedControlMasterSSHOptions
            }
            guard connectionBroker.retainResolvedControlMasterLease(
                for: configuration,
                controlPath: resolvedPath
            ) else {
                return nil
            }
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
        resolvedControlMasterSSHOptions = resolvedOptions
        return resolvedOptions
    }
}
