import CmuxCloud
import Foundation

@MainActor
extension CmuxTuiSurfaceProviderRegistry {
    fileprivate func installSessionGateObservers() {
        guard sessionRejectedObserver == nil else { return }
        sessionRejectedObserver = NotificationCenter.default.addObserver(
            forName: VMClient.sessionRejectedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sessionRejected = true
                for provider in self.providers.values { provider.noteSessionRejected() }
                self.pollTask?.cancel(); self.pollTask = nil
                self.refreshInFlight?.cancel(); self.refreshInFlight = nil
                self.discoveryInFlight?.cancel(); self.discoveryInFlight = nil
                self.refreshGeneration &+= 1
            }
        }
        sessionRecoveredObserver = NotificationCenter.default.addObserver(
            forName: VMClient.sessionRecoveredNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isRetired else { return }
                self.sessionRejected = false
                for provider in self.providers.values { provider.resetSessionRejectionAfterAuthChange() }
                self.syncPollingToActivationPolicy()
                let ids = Array(self.providers.keys)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for id in ids { await self.links.resetRetry(machineID: id) }
                    _ = await self.refresh(force: true)
                }
            }
        }
    }

    fileprivate func removeSessionGateObservers() {
        if let sessionRejectedObserver { NotificationCenter.default.removeObserver(sessionRejectedObserver) }
        if let sessionRecoveredObserver { NotificationCenter.default.removeObserver(sessionRecoveredObserver) }
    }
}
