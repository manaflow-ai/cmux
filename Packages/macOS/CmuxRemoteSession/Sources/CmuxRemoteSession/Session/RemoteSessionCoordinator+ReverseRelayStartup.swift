internal import Foundation

private enum ConflictedControlMasterExitOutcome: Sendable {
    case exited
    case ignored(String)
}

extension RemoteSessionCoordinator {
    /// Exits a legacy ControlPersist master only after the dedicated relay
    /// proves that its configured remote port is already bound.
    ///
    /// OpenSSH cannot cancel an inherited reverse forward without its original
    /// full target specification. Exiting the owning master is the only
    /// deterministic migration path; persistent remote PTYs survive and active
    /// transports reconnect.
    @discardableResult
    func beginConflictedControlMasterExitIfNeededLocked(
        startupFailure: String,
        remotePath: String,
        relayPort: Int,
        relayID: String,
        relayToken: String,
        localSocketPath: String
    ) -> Bool {
        guard reverseRelayStartupPhase.canAttemptRecovery,
              Self.isReverseRelayPortBindingFailure(
                  startupFailure,
                  relayPort: relayPort
              ) else {
            return false
        }

        let arguments = RemoteControlMasterCleanup()
            .cleanupArguments(configuration: configuration)
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
                    relayPort: relayPort,
                    relayID: relayID,
                    relayToken: relayToken,
                    localSocketPath: localSocketPath
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
        relayPort: Int,
        relayID: String,
        relayToken: String,
        localSocketPath: String
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

        guard !isStopping, daemonReady, reverseRelayProcess == nil else { return }
        launchReverseRelayLocked(
            remotePath: remotePath,
            relayPort: relayPort,
            relayID: relayID,
            relayToken: relayToken,
            localSocketPath: localSocketPath
        )
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
