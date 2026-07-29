internal import CmuxFoundation
internal import Foundation

private enum ConflictedControlMasterExitOutcome: Sendable {
    case exited
    case ignored(String)
}

extension RemoteSessionCoordinator {
    /// Exits a cmux-owned ControlPersist master only after OpenSSH proves that
    /// the configured relay port is already bound.
    ///
    /// OpenSSH cannot cancel an inherited reverse forward without its original
    /// full target specification. Custom ControlPaths fail closed here: cmux
    /// never terminates a master it did not create.
    @discardableResult
    func beginConflictedControlMasterExitIfNeededLocked(
        startupFailure: String,
        remotePath: String,
        relayPort: Int
    ) -> Bool {
        guard Self.isReverseRelayPortBindingFailure(
            startupFailure,
            relayPort: relayPort
        ) else {
            return false
        }
        guard reverseRelayStartupPhase.canAttemptRecovery else {
            return false
        }
        let effectiveSSHOptions = reverseRelayControlMasterSSHOptions
        guard SSHConnectionSharingOptions().cmuxOwnedControlPath(
            in: effectiveSSHOptions
        ) != nil else {
            debugLog(
                "remote.relay.conflictedMaster.exitSkipped " +
                "reason=control-path-not-owned relayPort=\(relayPort) " +
                debugConfigSummary()
            )
            return false
        }

        guard reverseRelayControlMasterForwardSpec == nil else {
            debugLog(
                "remote.relay.conflictedMaster.exitSkipped " +
                "reason=current-forward-owned relayPort=\(relayPort) " +
                debugConfigSummary()
            )
            return false
        }

        let arguments = RemoteControlMasterCleanup()
            .cleanupArguments(
                configuration: configuration,
                sshOptionsOverride: effectiveSSHOptions
            )
        let request = RemoteProcessRequest(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            environment: configuration.sshProcessEnvironment,
            timeout: 4
        )
        let token = UUID()
        let cancellation = RemoteProcessCancellationOperation()
        let processRunner = self.processRunner

        let task = Task { [weak self] in
            let outcome = await withTaskCancellationHandler {
                await Self.runConflictedControlMasterExit(
                    request: request,
                    processRunner: processRunner,
                    cancellation: cancellation
                )
            } onCancel: {
                cancellation.cancel()
            }
            guard !Task.isCancelled else { return }
            self?.queue.async { [weak self] in
                self?.finishConflictedControlMasterExitLocked(
                    token: token,
                    outcome: outcome,
                    remotePath: remotePath,
                    relayPort: relayPort
                )
            }
        }
        reverseRelayStartupPhase = .exitingConflictedControlMaster(
            token: token,
            task: task,
            cancellation: cancellation
        )
        debugLog(
            "remote.relay.conflictedMaster.exitBegin " +
            "relayPort=\(relayPort) \(debugConfigSummary())"
        )
        return true
    }

    /// Runs blocking `ssh -O exit` without occupying the coordinator queue or
    /// Swift's cooperative executor.
    private static func runConflictedControlMasterExit(
        request: RemoteProcessRequest,
        processRunner: any RemoteSessionProcessRunning,
        cancellation: RemoteProcessCancellationOperation
    ) async -> ConflictedControlMasterExitOutcome {
        await withCheckedContinuation { continuation in
            // The process runner is intentionally blocking. Keep that legacy
            // boundary on a utility thread while the owning Task suspends.
            DispatchQueue.global(qos: .utility).async {
                let outcome: ConflictedControlMasterExitOutcome
                do {
                    let result = try processRunner.run(request, operation: cancellation)
                    if result.status == 0 {
                        outcome = .exited
                    } else {
                        let detail = bestErrorLine(stderr: result.stderr, stdout: result.stdout)
                            ?? "ssh exited \(result.status)"
                        outcome = .ignored(detail)
                    }
                } catch {
                    outcome = .ignored(error.localizedDescription)
                }
                continuation.resume(returning: outcome)
            }
        }
    }

    /// Re-enters queue confinement and retries only after `ssh -O exit`
    /// completes and this recovery phase still owns the token.
    private func finishConflictedControlMasterExitLocked(
        token: UUID,
        outcome: ConflictedControlMasterExitOutcome,
        remotePath: String,
        relayPort: Int
    ) {
        guard reverseRelayStartupPhase.token == token else { return }
        reverseRelayStartupPhase = .recoveryAttempted

        switch outcome {
        case .exited:
            debugLog(
                "remote.relay.conflictedMaster.exited " +
                "relayPort=\(relayPort) \(debugConfigSummary())"
            )
        case .ignored(let detail):
            debugLog(
                "remote.relay.conflictedMaster.exitIgnored " +
                "relayPort=\(relayPort) \(detail) \(debugConfigSummary())"
            )
            publishDaemonStatus(
                .error,
                detail: String(
                    localized: "remoteSession.reverseRelay.portUnavailableRetrying",
                    defaultValue: "Remote SSH relay port unavailable; retrying in 2 seconds"
                )
            )
            scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
            return
        }

        guard !isStopping else { return }
        scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
    }

    /// Cancels the in-flight OpenSSH recovery and invalidates its continuation.
    func cancelReverseRelayStartupLocked() {
        guard case .exitingConflictedControlMaster(
            _,
            let task,
            let cancellation
        ) = reverseRelayStartupPhase else {
            return
        }
        reverseRelayStartupPhase = .recoveryAttempted
        task.cancel()
        cancellation.cancel()
    }
}
