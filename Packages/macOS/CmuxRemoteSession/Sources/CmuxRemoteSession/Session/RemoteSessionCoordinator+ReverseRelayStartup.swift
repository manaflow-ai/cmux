internal import CmuxFoundation
internal import Foundation

extension RemoteSessionCoordinator {
    /// Reaps a cmux-owned ControlPersist master only after OpenSSH proves that
    /// this relay's port is bound and remote metadata proves cmux ownership.
    ///
    /// OpenSSH cannot cancel an inherited reverse forward without its original
    /// local target. Reaping the exclusively owned master is therefore the only
    /// backward-compatible operation that preserves the remote lease port.
    @discardableResult
    func beginInheritedControlMasterReapIfNeededLocked(
        startupFailure: String,
        remotePath: String,
        relayPort: Int,
        resolvedControlPath: String?
    ) -> Bool {
        guard Self.isReverseRelayPortBindingFailure(
            startupFailure,
            relayPort: relayPort
        ) else {
            return false
        }
        guard controlMasterReapState.startupPhase
            .canAttemptRecovery else {
            return false
        }
        guard reverseRelayControlMasterForwardSpec == nil else {
            debugLog(
                "remote.relay.inheritedMaster.reapSkipped " +
                    "reason=current-forward-owned relayPort=\(relayPort) " +
                    debugConfigSummary()
            )
            return false
        }
        guard let relayID = configuration.relayID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !relayID.isEmpty,
            let relayToken = configuration.relayToken?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !relayToken.isEmpty else {
            return false
        }

        let probeScript = Self.remoteRelayMetadataOwnershipProbeScript(
            relayPort: relayPort,
            relayID: relayID,
            relayToken: relayToken,
            persistentDaemonSlot: configuration.persistentDaemonSlot
        )
        // Keep the relay token out of SSH argv and process/debug logs. The
        // ownership probe receives its script over stdin instead.
        let metadataProbeCommand = "sh -s"
        let metadataProbeStdin = Data(probeScript.utf8)
        let token = UUID()
        let configuration = self.configuration
        let connectionBroker = self.connectionBroker
        let processRunner = self.processRunner
        let resolutionAttempt: NativeSSHControlPathResolutionAttempt?
        if resolvedControlPath != nil {
            resolutionAttempt = nil
        } else {
            guard let effectiveOptions = resolvedControlMasterSSHOptions,
                  let ownedPath = connectionBroker.sharingOptions
                    .cmuxOwnedControlPath(in: effectiveOptions),
                  ownedPath.contains("%") else {
                return false
            }
            let resolver = NativeSSHControlPathResolver(
                sharingOptions: connectionBroker.sharingOptions
            )
            let request = RemoteProcessRequest(
                executable: "/usr/bin/ssh",
                arguments: resolver.resolutionArguments(
                    configuration: configuration,
                    effectiveOptions: effectiveOptions
                ),
                environment: configuration.sshProcessEnvironment,
                timeout: 5
            )
            resolutionAttempt = NativeSSHControlPathResolutionAttempt(
                request: request,
                resolver: resolver,
                effectiveOptions: effectiveOptions,
                processRunner: processRunner
            )
        }
        let task = Task { [weak self] in
            let effectiveControlPath: String?
            if let resolutionAttempt {
                effectiveControlPath = await resolutionAttempt.run()
                guard !Task.isCancelled else { return }
            } else {
                effectiveControlPath = resolvedControlPath
            }
            guard let effectiveControlPath else {
                self?.queue.async { [weak self] in
                    self?.finishInheritedControlMasterReapLocked(
                        token: token,
                        outcome: .deferred(
                            "could not resolve the cmux SSH ControlPath"
                        ),
                        remotePath: remotePath,
                        relayPort: relayPort
                    )
                }
                return
            }
            let outcome =
                await connectionBroker.reapInheritedControlMaster(
                    for: configuration,
                    resolvedControlPath: effectiveControlPath,
                    metadataProbeCommand: metadataProbeCommand,
                    metadataProbeStdin: metadataProbeStdin
                )
            guard !Task.isCancelled else { return }
            self?.queue.async { [weak self] in
                self?.finishInheritedControlMasterReapLocked(
                    token: token,
                    outcome: outcome,
                    remotePath: remotePath,
                    relayPort: relayPort
                )
            }
        }
        controlMasterReapState.startupPhase =
            .reapingInheritedControlMaster(
            token: token,
            task: task
        )
        debugLog(
            "remote.relay.inheritedMaster.reapBegin " +
                "relayPort=\(relayPort) \(debugConfigSummary())"
        )
        return true
    }

    private func finishInheritedControlMasterReapLocked(
        token: UUID,
        outcome: NativeSSHControlMasterReapOutcome,
        remotePath: String,
        relayPort: Int
    ) {
        guard controlMasterReapState.startupPhase.token == token else {
            return
        }
        switch outcome {
        case .reaped(let eventID):
            controlMasterReapState.startupPhase = .recoveryAttempted
            debugLog(
                "remote.relay.inheritedMaster.reaped " +
                    "relayPort=\(relayPort) \(debugConfigSummary())"
            )
            handleSharedControlMasterReapLocked(eventID: eventID)
        case .deferred(let detail):
            controlMasterReapState.startupPhase = .recoveryAvailable
            debugLog(
                "remote.relay.inheritedMaster.reapDeferred " +
                    "relayPort=\(relayPort) \(detail) " +
                    debugConfigSummary()
            )
            publishReverseRelayPortUnavailableLocked()
            scheduleReverseRelayRestartLocked(
                remotePath: remotePath,
                delay: 2.0
            )
        case .ignored(let detail):
            controlMasterReapState.startupPhase = .recoveryAttempted
            debugLog(
                "remote.relay.inheritedMaster.reapIgnored " +
                    "relayPort=\(relayPort) \(detail) " +
                    debugConfigSummary()
            )
            publishReverseRelayPortUnavailableLocked()
            scheduleReverseRelayRestartLocked(
                remotePath: remotePath,
                delay: 2.0
            )
        }
    }

    /// Invalidates every local transport that shared the reaped master and
    /// enters the normal reconnect state machine.
    func handleSharedControlMasterReapLocked(eventID: UUID) {
        guard controlMasterReapState.lastHandledEventID != eventID else {
            return
        }
        controlMasterReapState.lastHandledEventID = eventID
        controlMasterReapState.startupPhase = .recoveryAttempted
        debugLog(
            "remote.relay.inheritedMaster.reapObserved " +
                debugConfigSummary()
        )
        // A parked session has no retry scheduled, so `.reconnecting` would
        // strand it without its verdict. Whatever ends the park (Reconnect,
        // wake) resets the transport itself.
        guard !isStopping, parkedState == nil else { return }
        resetTransportForReconnectLocked(
            preservePersistentRelayMetadata: true
        )
        publishDaemonStatus(.bootstrapping, detail: nil)
        publishState(.reconnecting, detail: nil)
        _ = scheduleReconnectLocked(baseDelay: 2.0)
    }

    func observeControlMasterReapsLocked(controlPath: String) {
        guard controlMasterReapState.observedControlPath !=
                controlPath else {
            return
        }
        controlMasterReapState.observationTask?.cancel()
        controlMasterReapState.observedControlPath = controlPath
        let connectionBroker = self.connectionBroker
        controlMasterReapState.observationTask = Task { [weak self] in
            guard let events =
                await connectionBroker.controlMasterReapEvents(
                    controlPath: controlPath
                ) else {
                return
            }
            for await eventID in events {
                guard !Task.isCancelled else { return }
                self?.queue.async { [weak self] in
                    self?.handleSharedControlMasterReapLocked(
                        eventID: eventID
                    )
                }
            }
        }
    }

    func cancelReverseRelayStartupLocked() {
        guard case .reapingInheritedControlMaster(
            _,
            let task
        ) = controlMasterReapState.startupPhase else {
            return
        }
        controlMasterReapState.startupPhase = .recoveryAttempted
        task.cancel()
    }

    func cancelControlMasterReapObservationLocked() {
        controlMasterReapState.observationTask?.cancel()
        controlMasterReapState.observationTask = nil
        controlMasterReapState.observedControlPath = nil
    }

    /// Returns whether OpenSSH reported that this relay's remote listener is
    /// already bound.
    static func isReverseRelayPortBindingFailure(_ detail: String, relayPort: Int) -> Bool {
        reverseRelayPortBindingFailureLine(in: detail, relayPort: relayPort) != nil
    }

    /// Extracts the exact bind diagnostic from standalone or multiplexed
    /// OpenSSH stderr. Multiplexing adds a prefix and may append a later
    /// summary line, so classification must inspect every line.
    static func reverseRelayPortBindingFailureLine(
        in detail: String,
        relayPort: Int
    ) -> String? {
        let expected = "remote port forwarding failed for listen port \(relayPort)"
        return detail
            .split(whereSeparator: \.isNewline)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .first(where: {
                $0 == expected || $0.hasSuffix(": \(expected)")
            })
    }

    private func publishReverseRelayPortUnavailableLocked() {
        publishDaemonStatus(.bootstrapping, detail: nil)
        publishState(.reconnecting, detail: nil)
    }
}
