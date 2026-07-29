internal import CmuxFoundation
internal import Foundation

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
        guard reverseRelayControlMasterForwardSpec == nil else {
            debugLog(
                "remote.relay.conflictedMaster.exitSkipped " +
                "reason=current-forward-owned relayPort=\(relayPort) " +
                debugConfigSummary()
            )
            return false
        }

        let token = UUID()
        let configuration = self.configuration
        let connectionBroker = self.connectionBroker

        let task = Task { [weak self] in
            let outcome = await connectionBroker.resetConflictedControlMaster(
                for: configuration
            )
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
            task: task
        )
        debugLog(
            "remote.relay.conflictedMaster.exitBegin " +
            "relayPort=\(relayPort) \(debugConfigSummary())"
        )
        return true
    }

    /// Re-enters queue confinement and retries only after `ssh -O exit`
    /// completes and this recovery phase still owns the token.
    private func finishConflictedControlMasterExitLocked(
        token: UUID,
        outcome: NativeSSHControlMasterResetOutcome,
        remotePath: String,
        relayPort: Int
    ) {
        guard reverseRelayStartupPhase.token == token else { return }
        switch outcome {
        case .reset:
            reverseRelayStartupPhase = .recoveryAttempted
            debugLog(
                "remote.relay.conflictedMaster.exited " +
                "relayPort=\(relayPort) \(debugConfigSummary())"
            )
        case .deferred(let detail):
            reverseRelayStartupPhase = .recoveryAvailable
            debugLog(
                "remote.relay.conflictedMaster.exitDeferred " +
                "relayPort=\(relayPort) \(detail) \(debugConfigSummary())"
            )
            publishReverseRelayPortUnavailableLocked()
            scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
            return
        case .ignored(let detail):
            reverseRelayStartupPhase = .recoveryAttempted
            debugLog(
                "remote.relay.conflictedMaster.exitIgnored " +
                "relayPort=\(relayPort) \(detail) \(debugConfigSummary())"
            )
            publishReverseRelayPortUnavailableLocked()
            scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
            return
        }

        guard !isStopping else { return }
        scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
    }

    private func publishReverseRelayPortUnavailableLocked() {
        publishDaemonStatus(
            .error,
            detail: strings.reverseRelayPortUnavailableRetrying
        )
    }

    /// Cancels the in-flight OpenSSH recovery and invalidates its continuation.
    func cancelReverseRelayStartupLocked() {
        guard case .exitingConflictedControlMaster(
            _,
            let task
        ) = reverseRelayStartupPhase else {
            return
        }
        reverseRelayStartupPhase = .recoveryAttempted
        task.cancel()
    }
}
