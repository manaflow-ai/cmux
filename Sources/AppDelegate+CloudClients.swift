import Foundation

extension AppDelegate {
    /// Configures the auth-backed cloud clients at the composition root:
    /// Cloud VMs, remotes, AI accounts, phone push, the mobile pairing host,
    /// the device registry, presence (heartbeat out, computers directory in),
    /// and the DEV paired-Mac backup publisher. Extracted from `configure` so
    /// the client roster can grow without growing `AppDelegate.swift`.
    func configureCloudClients(auth: MacAuthComposition) {
        VMClient.bootstrap(auth: auth.coordinator)
        RemotesClient.bootstrap(auth: auth.coordinator)
        AIAccountsClient.bootstrap(auth: auth.coordinator)
        PhonePushClient.shared.configure(auth: auth.coordinator)
        MobileHostService.shared.configure(auth: auth.coordinator)
        DeviceRegistryClient.shared.configure(auth: auth.coordinator)
        PresenceHeartbeatClient.shared.configure(auth: auth.coordinator)
        // The Mac-as-client side of hive: the Settings › Computers directory
        // (registry list + local pairings + presence subscribe).
        HiveComputersService.shared.configure(auth: auth.coordinator)
        // DEV-only: auto-publish this Mac's attach route to the signed-in user's
        // pairedMacs backup so a fresh dev iOS build restores it (no manual host
        // entry). No-op on Release / when the flag is off.
        MacPairedMacBackupPublisher.shared.configure(auth: auth.coordinator)
    }
}
