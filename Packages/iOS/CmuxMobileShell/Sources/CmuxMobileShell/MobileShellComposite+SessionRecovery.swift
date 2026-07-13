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
        connectionGeneration = UUID()
        stopTerminalRefreshPolling()
        await client.resetConnectionForRecovery()

        guard connectionState == .connected, remoteClient === client else {
            return false
        }
        resyncTerminalOutput(reason: reason, restartEventStream: true)
        return true
    }
}
