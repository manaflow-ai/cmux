internal import CmuxMobileRPC
import Foundation

@MainActor
extension MobileShellComposite {
    func markMacConnectionHealthy(completingRecovery: Bool = false) {
        guard connectionState == .connected else {
            macConnectionStatus = .unavailable
            return
        }
        if completingRecovery {
            completeMobileConnectionRecovery()
        } else if case .reconnectingStoredRoute(let recoveryID) = connectionRecoveryState {
            connectionRecoveryState = .awaitingStoredRouteSubscription(recoveryID)
        }
        if connectionRecoveryState != nil {
            macConnectionStatus = .reconnecting
            isRecoveringConnection = true
            connectionRecoveryFailed = false
            connectionRequiresReauth = false
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
        guard connectionRecoveryState == nil else { return }
        if connectionState == .connected,
           remoteClient != nil,
           !trigger.resetsConnectedSession {
            markMacConnectionReconnecting()
            resyncTerminalOutput(reason: "networkRecovery.\(trigger)", restartEventStream: true)
            return
        }

        let recoveryID = UUID()
        isRecoveringConnection = true
        connectionRecoveryFailed = false
        let stackUserID = lastReconnectStackUserID
        let connectedClient = connectionState == .connected ? remoteClient : nil
        let connectedGeneration = connectionGeneration
        if connectedClient == nil
            || (trigger == .manual && macConnectionStatus == .unavailable) {
            connectionRecoveryState = .reconnectingStoredRoute(recoveryID)
            startStoredRouteRecovery(recoveryID: recoveryID, stackUserID: stackUserID)
            return
        }
        guard let connectedClient else { return }

        connectionRecoveryState = .resettingSession(recoveryID)
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let isAwaitingSubscriptionAck = await self.resetRemoteSessionForRecovery(
                client: connectedClient,
                expectedGeneration: connectedGeneration,
                recoveryID: recoveryID,
                reason: "networkRecovery.\(trigger)"
            )
            guard self.recoveryID == recoveryID, !Task.isCancelled else { return }
            guard isAwaitingSubscriptionAck else {
                self.startStoredRouteRecovery(
                    recoveryID: recoveryID,
                    stackUserID: stackUserID
                )
                return
            }
            if self.multiMacAggregationEnabled, trigger.reschedulesSecondaryAggregation {
                self.scheduleSecondaryAggregation()
            }
        }
    }

    func cancelMobileConnectionRecovery() {
        connectionRecoveryState = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        isRecoveringConnection = false
    }

    func completeMobileConnectionRecovery() {
        guard connectionRecoveryState != nil else { return }
        connectionRecoveryState = nil
        recoveryTask = nil
        isRecoveringConnection = false
        connectionRecoveryFailed = false
    }

    @discardableResult
    func handleMobileConnectionRecoverySubscriptionFailure() -> Bool {
        guard let recoveryState = connectionRecoveryState else { return false }
        switch recoveryState {
        case .resettingSession(let recoveryID),
             .awaitingResetSubscription(let recoveryID):
            startStoredRouteRecovery(
                recoveryID: recoveryID,
                stackUserID: lastReconnectStackUserID
            )
        case .reconnectingStoredRoute, .awaitingStoredRouteSubscription:
            connectionRecoveryState = nil
            recoveryTask = nil
            markMacConnectionUnavailable()
        }
        return true
    }

    private func startStoredRouteRecovery(recoveryID: UUID, stackUserID: String?) {
        guard self.recoveryID == recoveryID else { return }
        connectionRecoveryState = .reconnectingStoredRoute(recoveryID)
        markMacConnectionReconnecting()
        stopTerminalRefreshPolling()
        connectionState = .disconnected
        clearRemoteConnectionContext(
            preservingOtherMacWorkspaceState: true,
            preservingConnectionRecovery: true
        )
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let reconnected = await self.reconnectActiveMacIfAvailable(
                stackUserID: stackUserID,
                preservingConnectionRecoveryOnFailure: true
            )
            guard self.recoveryID == recoveryID, !Task.isCancelled else { return }
            guard reconnected else {
                self.connectionRecoveryState = nil
                self.recoveryTask = nil
                self.markMacConnectionUnavailable()
                self.connectionRecoveryFailed = true
                return
            }
            guard self.runtime?.supportsServerPushEvents == true else {
                self.completeMobileConnectionRecovery()
                self.markMacConnectionHealthy()
                return
            }
            if case .reconnectingStoredRoute = self.connectionRecoveryState {
                self.connectionRecoveryState = .awaitingStoredRouteSubscription(recoveryID)
            }
            self.markMacConnectionReconnecting()
        }
    }

    /// Replaces only the stale transport while preserving the paired-Mac session context.
    func resetRemoteSessionForRecovery(
        client: MobileCoreRPCClient,
        expectedGeneration: UUID,
        recoveryID: UUID,
        reason: String
    ) async -> Bool {
        guard connectionState == .connected,
              remoteClient === client,
              connectionGeneration == expectedGeneration,
              self.recoveryID == recoveryID else {
            return false
        }

        markMacConnectionReconnecting()
        let recoveryGeneration = UUID()
        connectionGeneration = recoveryGeneration
        stopTerminalRefreshPolling()
        await client.resetConnectionForRecovery()

        guard connectionState == .connected,
              remoteClient === client,
              connectionGeneration == recoveryGeneration,
              self.recoveryID == recoveryID else {
            return false
        }
        connectionRecoveryState = .awaitingResetSubscription(recoveryID)
        resyncTerminalOutput(reason: reason, restartEventStream: true)
        return true
    }
}
