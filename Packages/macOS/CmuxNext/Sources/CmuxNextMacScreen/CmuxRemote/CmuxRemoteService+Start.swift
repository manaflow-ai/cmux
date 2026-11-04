import CmuxNextCompat
public import CmuxNextComputerUse
public import CmuxNextDevices
public import CmuxNextSettings
import Foundation
import os

private let startLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "cmux-remote")

extension CmuxRemoteService {
    /// cmux Remote's app side (docs/cmux-remote.md), when this build embeds it: Computer Use
    /// runs as its worker; the hub is made with the Screen Sharing worker's device identity and
    /// reads the worker's one User DO socket, and the worker is anchored while signed in; Mac
    /// Screen's host sessions and approval banner are the worker's. Nil (and nothing changes) in
    /// a build without the bundle.
    public func start(bundleID: String, deviceHub: DeviceHubService, pages: MacScreenPages, computerUse: ComputerUseHelperV2,
                      tokens: @escaping @Sendable () async throws -> String) -> CmuxRemoteDevices? {
        guard !started, let executable = ComputerUseRemoteSource.executable() else { return nil }
        markStarted()
        let devices = CmuxRemoteDevices(open: { [weak self] in
            guard let self else { throw CmuxRemoteError.unavailable }
            return try await openChannel("screen-sharing").socket
        })
        computerUse.remote = ComputerUseRemoteSource(available: { [weak self] in
            await self?.waitAvailable() ?? false
        }, open: { [weak self] in
            guard let self else { throw CmuxRemoteError.unavailable }
            // A tagged DEV app may be driven (the legacy dogfood scope); only this app opens a channel.
            let opened = try await openChannel("computer-use", extra: ["allowed_target_bundle_id": bundleID])
            return ComputerUseRemoteChannel(pid: opened.pid, socket: opened.socket, executable: executable)
        })
        deviceHub.makeRemoteHub = { [weak self] url, _ in
            guard let self else { return nil }
            remoteHub = nil
            guard await waitAvailable() else { return nil }
            do {
                let identity = try await devices.identity()
                let client = DeviceHubClient(baseURL: url, identity: identity, tokens: DeviceHubAccountToken(tokens))
                let hub = DeviceHub(client: client, socket: DeviceHubSocket(connector: RemotePushConnector(devices: devices)),
                                    secrets: KeychainRelaySecretStore(bundleIdentifier: bundleID), deviceName: MacScreenShareHost.computerName)
                remoteHub = hub
                return hub
            } catch {
                startLogger.error("cmux Remote device identity: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        deviceHub.hubChanged = { [weak self, weak pages] hub, user, url in
            guard let self else { return }
            // cmux Remote serves this Mac only when the running hub is its device (else the app's own hub serves).
            let remote = hub != nil && hub === remoteHub
            followHub(remote ? hub : nil, userID: user, hubURL: url, devices: devices)
            pages?.remoteHosted = remote
        }
        return devices
    }

    /// Sends the person's switches whenever `config` (read inside an observation) changes.
    public func follow(_ settings: SettingsController, config: @escaping @MainActor () -> (computerUse: Bool, screenSharing: Bool, headless: Bool)) {
        currentConfig = config
        // task-owner: lives with the app; follows the settings, the sign-in and the daemon.
        Task { [weak self, weak settings] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            for await next in ObservationStream({ config() }) {
                guard let self else { return }
                await apply(computerUse: next.computerUse, screenSharing: next.screenSharing, headless: next.headless)
            }
        }
    }
}
