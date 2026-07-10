@MainActor
extension MobileShellComposite {
    enum RecoveryTrigger: CustomStringConvertible {
        case networkChange
        case manual
        case presencePush

        var reschedulesSecondaryAggregation: Bool { self != .presencePush }

        var description: String {
            switch self {
            case .networkChange: return "networkChange"
            case .manual: return "manual"
            case .presencePush: return "presencePush"
            }
        }
    }

    /// Begin observing every post-initial network path callback so a live
    /// terminal recovers and plaintext trust is revoked when the network moves
    /// out from under it. Idempotent; only the first call arms the observation.
    func startObservingNetworkPathChanges() {
        guard !networkPathObservationStarted else { return }
        networkPathObservationStarted = true
        let reachability = reachability
        networkPathObservationTask = Task { @MainActor [weak self] in
            // Every post-initial callback is a security boundary. Public NWPath
            // attributes can look identical across two different Wi-Fi LANs.
            for await _ in reachability.pathChanges() {
                guard let self, !Task.isCancelled else { return }
                if self.invalidateManualHostTrustForNetworkBoundary() {
                    continue
                }
                self.recoverMobileConnection(trigger: .networkChange)
            }
        }
    }

    /// User-initiated reconnect from the Retry control.
    public func retryMobileConnection() {
        connectionRecoveryFailed = false
        recoverMobileConnection(trigger: .manual)
    }

    /// Single guarded recovery entry for every trigger (network change, manual
    /// Retry). Connected sessions resync; disconnected sessions reconnect. A
    /// later network boundary records one trailing attempt instead of cancelling
    /// or losing the recovery whose authorization scope it just superseded.
    func recoverMobileConnection(trigger: RecoveryTrigger) {
        guard remoteClient != nil || pairedMacStore != nil else { return }
        if recoveryInFlight || isRecoveringConnection {
            if trigger == .networkChange {
                networkRecoveryPending = true
            }
            return
        }
        if connectionState == .connected, remoteClient != nil {
            markMacConnectionReconnecting()
            resyncTerminalOutput(reason: "networkRecovery.\(trigger)", restartEventStream: true)
            if multiMacAggregationEnabled, trigger.reschedulesSecondaryAggregation {
                scheduleSecondaryAggregation()
            }
            return
        }
        recoveryInFlight = true
        isRecoveringConnection = true
        connectionRecoveryFailed = false
        let stackUserID = lastReconnectStackUserID
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            defer { self?.finishMobileConnectionRecoveryAttempt() }
            guard let self, self.connectionState != .connected else { return }
            let reconnected = await self.reconnectActiveMacIfAvailable(stackUserID: stackUserID)
            if !reconnected, !Task.isCancelled {
                self.connectionRecoveryFailed = true
            }
        }
    }

    func finishMobileConnectionRecoveryAttempt() {
        recoveryInFlight = false
        isRecoveringConnection = false
        recoveryTask = nil
        drainPendingNetworkRecoveryIfIdle()
    }

    func drainPendingNetworkRecoveryIfIdle() {
        guard networkRecoveryPending,
              !recoveryInFlight,
              !isRecoveringConnection else { return }
        networkRecoveryPending = false
        recoverMobileConnection(trigger: .networkChange)
    }
}
