import AppKit
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDevices
import CmuxNextMacScreen
import CmuxNextSettings
import Foundation
import os

/// The device hub for this app (docs/device-hub/PROTOCOL.md): made when
/// the cmux account is signed in, at the build's built-in hub address (DEV
/// builds: the dev hub, unless `deviceHub.url` overrides it), started on
/// sign-in (registers this Mac as a device and keeps the User DO socket
/// open) and stopped on sign-out, after ending this Mac's sessions. Mac
/// Screen and Settings > Devices read it through `MacScreenPages.hub`.
/// This Mac's name is the computer name unless the person renamed it in
/// Settings > Devices.
@MainActor
final class DeviceHubService {
    private let pages: MacScreenPages
    private let auth: CloudAuth
    private let bundleIdentifier: String
    /// Settings > Devices (the React page's `devices` card).
    let settingsModel: MacScreenDevicesSettings
    private var hub: DeviceHub?
    /// What the running hub was made for: its address and the account.
    private var running: (url: URL, user: String)?
    /// This Mac removed itself: it stays out until the person signs in again (or relaunches).
    private var leftHub = false
    private var url: URL?
    /// The signed-in account's user id; nil when signed out.
    private var user: String?
    private var watch: Task<Void, Never>?
    /// Follows the running hub's socket: another device removed this Mac.
    private var removalWatch: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "device-hub")

    init(pages: MacScreenPages, auth: CloudAuth, bundleIdentifier: String?) {
        self.pages = pages
        self.auth = auth
        self.bundleIdentifier = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        settingsModel = MacScreenDevicesSettings(pages: pages)
        settingsModel.canSignIn = { [weak self] in self?.leftHub ?? false }
        settingsModel.signIn = { [weak self] in
            guard let self else { return }
            leftHub = false
            reconcile()
        }
        settingsModel.thisDeviceRemoved = { [weak self] in
            guard let self else { return }
            leftHub = true
            stopHub(endingSessions: false, removed: true)
        }
        settingsModel.thisDeviceRenamed = { [weak pages] name in pages?.store.setHubDeviceName(name) }
    }

    /// Follows the hub address and the account from now on.
    func start(settings: SettingsController) {
        guard watch == nil else { return }
        let auth = auth
        // task-owner: DeviceHubService.watch: follows deviceHub.url and sign-in for the app's life
        watch = Task { [weak self] in
            await auth.awaitRestored()
            await self?.pages.store.load()
            for await (address, user) in ObservationStream({ (Self.address(settings), auth.isSignedIn ? (auth.user?.id ?? "") : nil) }) {
                guard let self else { return }
                url = address
                self.user = user
                pages.hubConfigured = url != nil
                reconcile()
            }
        }
    }

    /// The hub's address: the build's built-in hub, or a DEV build's valid
    /// `deviceHub.url` override; nil only when that override is not valid.
    private static func address(_ settings: SettingsController) -> URL? {
        settings.snapshot.deviceHub.resolvedBaseURL(isDebugBuild: ControlService.isDebugBuild)
    }

    private func reconcile() {
        guard let url, let user, !leftHub else {
            stopHub(endingSessions: true)
            return
        }
        if let running, running.url == url, running.user == user, hub != nil { return }
        stopHub(endingSessions: true)
        startHub(url: url, user: user)
    }

    private func startHub(url: URL, user: String) {
        let auth = auth
        let name = pages.store.hubDeviceName ?? MacScreenShareHost.computerName
        let hub: DeviceHub
        do {
            hub = try DeviceHub.forApp(baseURL: url, bundleIdentifier: bundleIdentifier, deviceName: name,
                                       tokens: DeviceHubAccountToken { try await auth.tokens().access })
        } catch {
            logger.error("device hub identity unavailable: \(String(describing: error), privacy: .public)")
            return
        }
        self.hub = hub
        running = (url, user)
        pages.hub = hub
        // task-owner: one registration and socket start; stop() cancels the socket
        Task { await hub.start() }
        // task-owner: DeviceHubService.removalWatch: lives with this hub; stopHub cancels it
        removalWatch = Task { [weak self] in
            for await removed in ObservationStream({ hub.connection == .removed }) where removed {
                // Another device removed this Mac: it leaves the hub until the person signs in again.
                guard let self, self.hub === hub else { return }
                leftHub = true
                stopHub(endingSessions: false, removed: true)
                return
            }
        }
        logger.info("device hub started")
    }

    /// A sign-out starts (the account's tokens still work): the hub hears
    /// `signed_out` now, not after the rest of the sign-out.
    func willSignOut() {
        stopHub(endingSessions: true)
    }

    /// Signed out (or another account, address or a removal): this Mac's
    /// sessions end here at once, and the hub hears why in the background
    /// (one device sign-out, `signed_out`, while the hub session still
    /// holds), then stops. Nothing here waits on the network: the main
    /// actor stays free. `removed`: another device (or this one) removed
    /// this Mac, so its sessions end with that reason, never "signed out".
    private func stopHub(endingSessions: Bool, removed: Bool = false) {
        removalWatch?.cancel()
        removalWatch = nil
        guard let hub else { return }
        self.hub = nil
        running = nil
        if removed { pages.endHubSessions(reason: "device_removed:viewer") }
        let ids = Set(hub.tickets.keys).union(pages.hubHost.session.map { [$0.id] } ?? [])
        pages.hub = nil
        guard endingSessions else {
            hub.stop()
            logger.info("device hub stopped")
            return
        }
        // task-owner: the sign-out call (an older hub: one /end per session), then the stop
        Task {
            do { try await hub.signOutDevice() } catch {
                await withTaskGroup(of: Void.self) { group in
                    for id in ids {
                        group.addTask { try? await hub.endSession(id, reason: MacScreenHubReason.signedOut.rawValue) }
                    }
                }
            }
            hub.stop()
        }
        logger.info("device hub signing out")
    }
}

extension AppServices {
    /// The device hub follows the hub address (`deviceHub.url` in DEV builds) and the cmux account.
    func startDeviceHub(_ settings: SettingsController) {
        deviceHub.start(settings: settings)
        cloud.willSignOut.append { [weak self] in self?.deviceHub.willSignOut() }
    }

    /// `debug.device_hub` (DEV builds).
    func registerDeviceHubDebug(on router: ControlRouter?) {
        macScreenPages.registerDeviceHubDebug(on: router, settings: deviceHub.settingsModel) { [weak self] record, key in
            let named = key.flatMap { key in self?.windows.controllers.lazy.compactMap { $0.content?.panes.values.first { $0.paneKey == key } }.first }
            guard let self, let pane = named ?? windows.active?.focusedPane ?? windows.controllers.first?.focusedPane else { return "no pane" }
            macScreenTabs.open(record, in: pane, focus: true, byPerson: true)
            return nil
        }
    }
}
