public import CmuxNextCompat
public import CmuxNextComputerUse
public import CmuxNextDevices
public import CmuxNextSettings
import Foundation
import os

private let startLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "cmux-helper-host")

extension CmuxHelperService {
    /// cmux Computer Use's app side (docs/computer-use-helper.md), when this build embeds it: Computer Use
    /// runs as its worker; the hub is made with the Screen Sharing worker's device identity and
    /// reads the worker's one User DO socket, and the worker is anchored while signed in. The app
    /// serves Mac Screen and shows approvals while attached. Nil (and nothing changes) in
    /// a build without the bundle.
    public func start(bundleID: String, loginKeychain: LoginKeychain, deviceHub: DeviceHubService, pages: MacScreenPages, computerUse: ComputerUseHelperV2,
                      tokens: @escaping @Sendable () async throws -> String) -> CmuxHelperDevices? {
        guard !started, let executable = ComputerUseHelperHostSource.executable() else { return nil }
        markStarted()
        let devices = CmuxHelperDevices(open: { [weak self] in
            guard let self else { throw CmuxHelperError.unavailable }
            return try await openChannel("screen-sharing").socket
        })
        computerUse.helperHost = ComputerUseHelperHostSource(available: { [weak self] in
            await self?.waitAvailable() ?? false
        }, open: { [weak self] in
            guard let self else { throw CmuxHelperError.unavailable }
            // A tagged DEV app may be driven (the legacy dogfood scope); only this app opens a channel.
            let opened = try await openChannel("computer-use", extra: ["allowed_target_bundle_id": bundleID])
            return ComputerUseHelperHostChannel(pid: opened.pid, socket: opened.socket, executable: executable)
        })
        deviceHub.makeRemoteHub = { [weak self] url, _ in
            guard let self else { return nil }
            remoteHub = nil
            guard try await configuredAvailability() else { return nil }
            do {
                let identity = try await devices.identity()
                let hub = devices.makeHub(url: url, identity: identity, bundleID: bundleID, loginKeychain: loginKeychain, tokens: tokens)
                remoteHub = hub
                return hub
            } catch {
                startLogger.error("cmux Computer Use device identity: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        deviceHub.hubChanged = { [weak self, weak pages] hub, user, url in
            guard let self else { return }
            // The app owns the current `cmux.rd/1` host while it is running. The worker's host
            // path speaks the older ScreenStreamHost protocol, so its app channel is explicitly
            // relay-only; it retains identity, signing and push delivery, and can host again only
            // after every app channel closes.
            let usesRemoteIdentity = hub != nil && hub === remoteHub
            followHub(usesRemoteIdentity ? hub : nil, userID: user, hubURL: url, devices: devices)
            pages?.remoteHosted = false
        }
        return devices
    }

    /// Uses one consent snapshot for new channels and changes on an existing worker. The caller
    /// invokes the returned callback after its consent model changes.
    public func bindConsent(_ devices: CmuxHelperDevices,
                            source: @escaping @MainActor () -> (enabled: Bool, view: Bool, full: Bool)) -> @MainActor () -> Void {
        devices.setConsentSource { await source() }
        return { [weak self] in
            let consent = source()
            // task-owner: one consent line to a running worker, bounded by its availability wait.
            Task { [weak self] in
                guard await self?.waitAvailable() == true else { return }
                await devices.consent(enabled: consent.enabled, view: consent.view, full: consent.full)
            }
        }
    }

    /// Sends the person's switches whenever settings or app state (read inside an observation) changes,
    /// from the first settings load on.
    public func follow(_ settings: SettingsController,
                       appState: @escaping @MainActor () -> (signedIn: Bool, computerUseAllowed: Bool)) {
        // task-owner: lives with the app; follows the settings, the sign-in and the daemon.
        Task { [weak self, weak settings] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            let config = { @MainActor in
                let state = appState(), computerUse = settings.snapshot.computerUse
                return (computerUse: computerUse.enabled && ComputerUseHelperDaemon.shared.effectiveDriver(computerUse.driver) == .upstream && state.computerUseAllowed,
                        screenSharing: state.signedIn, headless: !settings.snapshot.remote.endSharingOnQuit)
            }
            self?.currentConfig = config
            for await next in ObservationStream(config) {
                guard let self else { return }
                await apply(computerUse: next.computerUse, screenSharing: next.screenSharing, headless: next.headless)
            }
        }
    }
}
