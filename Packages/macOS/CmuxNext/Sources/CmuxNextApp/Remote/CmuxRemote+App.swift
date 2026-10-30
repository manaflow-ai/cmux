import CmuxNextComputerUse
import CmuxNextDaemon
import CmuxNextDevices
import CmuxNextMacScreen
import CmuxNextSettings
import Foundation
import os

private let wiringLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "cmux-remote")

extension AppServices {
    /// cmux Remote (docs/cmux-remote.md), when this build embeds it: the daemon supervises the
    /// one host that holds the grants; Computer Use runs as its worker, and its Screen Sharing
    /// worker is this Mac on the device hub (banner, sessions, with the app quit too). A build
    /// without the bundle keeps the helper v2 and the in-app host.
    func startCmuxRemote(_ settings: SettingsController) {
        guard CmuxRemoteService.shared == nil, let executable = CmuxRemoteComputerUse.executable() else { return }
        let remote = CmuxRemoteService(daemon: daemon)
        CmuxRemoteService.shared = remote
        let devices = CmuxRemoteDevices(open: { try await remote.openChannel("screen-sharing").socket })
        let bundleID = environment.launch.bundleID
        ComputerUseHelperDaemon.shared.upstream.remote = CmuxRemoteComputerUse(open: {
            // A tagged DEV app may be driven (the legacy dogfood scope); only this app opens a channel.
            let opened = try await remote.openChannel("computer-use", extra: ["allowed_target_bundle_id": bundleID])
            return ComputerUseRemoteChannel(pid: opened.pid, socket: opened.socket, executable: executable)
        })
        let auth = cloud.auth
        deviceHub.makeRemoteHub = { [weak remote] url, _ in
            guard let remote, await remote.waitAvailable() else { return nil }
            do {
                let identity = try await devices.identity()
                let client = DeviceHubClient(baseURL: url, identity: identity, tokens: DeviceHubAccountToken { try await auth.tokens().access })
                return DeviceHub(client: client, socket: DeviceHubSocket(connector: RemotePushConnector(devices: devices)),
                                 secrets: KeychainRelaySecretStore(bundleIdentifier: bundleID), deviceName: MacScreenShareHost.computerName)
            } catch {
                wiringLogger.error("cmux Remote device identity: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        deviceHub.hubChanged = { [weak self, weak remote] hub, user, url in
            guard let self, let remote else { return }
            remote.followHub(hub, userID: user, hubURL: url, devices: devices)
            macScreenPages.remoteHosted = hub != nil && remote.available
        }
        let consent = joinConsent
        let previous = consent.changed
        consent.changed = { [weak consent] in
            previous()
            guard let consent else { return }
            let (enabled, view, full) = (consent.enabled, consent.permitsMacScreen(control: false), consent.permitsMacScreen(control: true))
            // task-owner: one consent line to the worker; it serves with the app quit too.
            Task { await devices.consent(enabled: enabled, view: view, full: full) }
        }
        remote.currentConfig = { [weak self, weak settings] in
            guard let self, let settings else { return (false, false, true) }
            let computerUse = settings.snapshot.computerUse
            let on = computerUse.enabled && computerUse.driver == .upstream && !registry.disabledFeatures.contains(.computerUse)
            return (on, cloud.isSignedIn, settings.snapshot.remote.headless)
        }
        // task-owner: CmuxRemoteService follows the settings, the sign-in and the daemon for the app's life.
        Task { [weak self, weak settings, weak remote] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            for await _ in ObservationStream({ [weak self] in
                (settings.snapshot.computerUse, settings.snapshot.remote, self?.cloud.isSignedIn, self?.daemon.identity?.capabilities.count)
            }) {
                guard let remote, let config = remote.currentConfig?() else { return }
                await remote.apply(computerUse: config.computerUse, screenSharing: config.screenSharing, headless: config.headless)
            }
        }
    }
}
