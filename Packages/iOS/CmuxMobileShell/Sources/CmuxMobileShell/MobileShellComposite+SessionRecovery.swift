internal import CmuxMobileRPC
import Foundation

@MainActor
extension MobileShellComposite {
    func markMacConnectionHealthy() {
        guard connectionState == .connected else {
            macConnectionStatus = .unavailable
            return
        }
        macConnectionStatus = .connected
        isRecoveringConnection = false
        connectionRecoveryFailed = false
        connectionRequiresReauth = false
    }

    func markMacConnectionReconnecting() {
        guard connectionState == .connected, remoteClient != nil else {
            macConnectionStatus = .unavailable
            return
        }
        macConnectionStatus = .reconnecting
        isRecoveringConnection = true
        connectionRecoveryFailed = false
    }

    func markMacConnectionUnavailable() {
        guard connectionState == .connected else {
            macConnectionStatus = .unavailable
            return
        }
        macConnectionStatus = .unavailable
        isRecoveringConnection = false
        connectionRecoveryFailed = true
    }

    func recoverMacConnectionIfNeeded(after error: any Error) {
        guard MobileShellMacAvailabilityFailureClassifier().isAvailabilityFailure(error) else { return }
        markMacConnectionReconnecting()
        recoverMobileConnection(trigger: .availabilityFailure)
    }

    /// Single-flight owner for every recovery trigger that can replace or
    /// re-subscribe the foreground session.
    func recoverMobileConnection(trigger: RecoveryTrigger) {
        guard remoteClient != nil || pairedMacStore != nil else { return }
        guard recoveryID == nil else { return }
        if connectionState == .connected,
           remoteClient != nil,
           !trigger.resetsConnectedSession {
            markMacConnectionReconnecting()
            resyncTerminalOutput(reason: "networkRecovery.\(trigger)", restartEventStream: true)
            return
        }

        let recoveryID = UUID()
        self.recoveryID = recoveryID
        isRecoveringConnection = true
        connectionRecoveryFailed = false
        let stackUserID = lastReconnectStackUserID
        let connectedClient = connectionState == .connected ? remoteClient : nil
        let connectedGeneration = connectionGeneration
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            var isAwaitingSubscriptionAck = false
            defer {
                if self?.recoveryID == recoveryID {
                    self?.recoveryID = nil
                    self?.recoveryTask = nil
                    if !isAwaitingSubscriptionAck {
                        self?.isRecoveringConnection = false
                    }
                }
            }
            guard let self else { return }
            if let connectedClient {
                isAwaitingSubscriptionAck = await self.resetRemoteSessionForRecovery(
                    client: connectedClient,
                    expectedGeneration: connectedGeneration,
                    reason: "networkRecovery.\(trigger)"
                )
                guard self.recoveryID == recoveryID, !Task.isCancelled else { return }
                if self.multiMacAggregationEnabled, trigger.reschedulesSecondaryAggregation {
                    self.scheduleSecondaryAggregation()
                }
                return
            }
            guard self.connectionState != .connected else { return }
            let reconnected = await self.reconnectActiveMacIfAvailable(stackUserID: stackUserID)
            guard self.recoveryID == recoveryID, !Task.isCancelled else { return }
            if !reconnected {
                self.connectionRecoveryFailed = true
            }
        }
    }

    func cancelMobileConnectionRecovery() {
        recoveryID = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        isRecoveringConnection = false
    }

    /// Replaces only the stale transport while preserving the paired-Mac session context.
    func resetRemoteSessionForRecovery(
        client: MobileCoreRPCClient,
        expectedGeneration: UUID,
        reason: String
    ) async -> Bool {
        guard connectionState == .connected,
              remoteClient === client,
              connectionGeneration == expectedGeneration else {
            return false
        }

        markMacConnectionReconnecting()
        let recoveryGeneration = UUID()
        connectionGeneration = recoveryGeneration
        stopTerminalRefreshPolling()
        await client.resetConnectionForRecovery()

        guard connectionState == .connected,
              remoteClient === client,
              connectionGeneration == recoveryGeneration else {
            return false
        }
        resyncTerminalOutput(reason: reason, restartEventStream: true)
        return true
    }
}
