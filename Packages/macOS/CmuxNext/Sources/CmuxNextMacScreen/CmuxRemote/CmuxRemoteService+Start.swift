public import CmuxNextCompat
public import CmuxNextComputerUse
public import CmuxNextDevices
public import CmuxNextSettings
import Foundation
import os

private let startLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "cmux-remote")

extension CmuxRemoteService {
    /// cmux Remote's app side (docs/cmux-remote.md), when this build embeds it: Computer Use
    /// runs as its worker; the hub is made with the Screen Sharing worker's device identity and
    /// reads the worker's one User DO socket, and the worker is anchored while signed in. The app
    /// keeps Mac Screen's tickets, consent and approvals while attached, and every session it
    /// serves is captured by the Screen Sharing worker; the grants are read and requested
    /// through the host. Nil (and nothing changes) in a build without the bundle: no Mac Screen
    /// session can be served then, since this app never captures the screen itself.
    public func start(bundleID: String, loginKeychain: LoginKeychain, deviceHub: DeviceHubService, pages: MacScreenPages, computerUse: ComputerUseHelperV2,
                      tokens: @escaping @Sendable () async throws -> String) -> CmuxRemoteDevices? {
        // In every build: without cmux Remote (Release, NIGHTLY) the app's own grants are the ones that count.
        followAppPermissions(activation: pages.systemShortcuts)
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
        attachMacScreen(pages)
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
                startLogger.error("cmux Remote device identity: \(String(describing: error), privacy: .public)")
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

    /// Mac Screen's capture and grants go through the helper host: each served session is one
    /// Screen Sharing worker channel, the grants are the host's probe, and a request is made by
    /// the host (`remote-host request …`), so macOS names cmux Computer Use, never cmux.
    func attachMacScreen(_ pages: MacScreenPages) {
        pages.hubHost.captureWorker = MacScreenCaptureWorker(channel: { [weak self] in
            guard let self else { throw CmuxRemoteError.unavailable }
            guard await waitAvailable() else { throw CmuxRemoteError.unavailable }
            return try await openChannel("screen-sharing").socket
        })
        pages.hubHost.sessionsSurviveQuit = { [weak self] in self?.currentConfig?().headless ?? false }
        pages.host.helper = MacScreenHelperPermissions(read: { [weak self] in
            guard let self else { throw CmuxRemoteError.unavailable }
            let status = try await call("refresh")
            let permissions = status["permissions"]
            guard let screen = permissions?["screen_recording"]?.boolValue,
                  let control = permissions?["accessibility"]?.boolValue else { throw CmuxRemoteError.refused("no permissions in the host's status") }
            return (screen, control, status["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
        }, request: { [weak self] screenRecording in
            guard let self else { throw CmuxRemoteError.unavailable }
            _ = try await call("request", .object(["permission": .string(screenRecording ? "screen-recording" : "accessibility")]))
        })
        // task-owner: the first read through the host; later ones follow app activation.
        Task { [weak pages] in await pages?.host.refreshPermissions() }
    }

    /// Uses one consent snapshot for new channels and changes on an existing worker. The caller
    /// invokes the returned callback after its consent model changes.
    public func bindConsent(_ devices: CmuxRemoteDevices,
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
