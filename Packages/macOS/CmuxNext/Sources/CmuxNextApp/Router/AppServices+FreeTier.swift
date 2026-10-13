import CmuxAppAttest
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextHomeEngine
import DeviceCheck
import Foundation
import os

extension AppServices {
    /// Offers this Mac's App Attest proofs to the local model relay for the
    /// free tier (cx-ds09i; the relay owns the lease, `FreeTierAttestProvider`).
    /// Follows `freeModel.enabled` and whether a profile or team policy sets
    /// it. Nil without acpmux or an API origin. The relay starts a lease only
    /// at the first signed-out agent request, never here.
    func startFreeTier() -> Task<Void, Never>? {
        let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        guard let acpmux = AgentTabPaneSource.paneEnvironment(tag: environment.tag, bundledBinDirectory: bin,
                                                               environment: ProcessInfo.processInfo.environment),
              let origin = HomeCloudLease.origin(feed.apiBaseURL) else { return nil }
        let provider = FreeTierAttestProvider(
            environment: acpmux, attest: AppleDeviceAttest(service: .shared, device: .current),
            keys: KeychainAttestKeyStore(service: "com.cmuxterm.next.free-tier.app-attest", account: "key"),
            logger: Logger(subsystem: "com.cmuxterm.next", category: "free-tier"))
        let settings = settings
        // task-owner: AppDelegate holds it and cancels it at termination; one provider start, then one update per setting change
        return Task {
            var started = false
            for await (enabled, managed) in ObservationStream({
                (settings?.snapshot.freeModel.enabled ?? true, settings?.managedKeys["freeModel.enabled"] != nil)
            }) {
                if started {
                    await provider.update(enabled: enabled, managed: managed)
                } else {
                    started = true
                    await provider.start(origin: origin, enabled: enabled, managed: managed)
                }
            }
            await provider.stop()
        }
    }
}
