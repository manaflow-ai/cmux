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
/// `deviceHub.url` is set (DEV builds read it) and the cmux account is
/// signed in, started on sign-in (registers this Mac as a device and keeps
/// the User DO socket open) and stopped on sign-out, after ending this
/// Mac's sessions. Mac Screen and Settings > Devices read it through
/// `MacScreenPages.hub`. This Mac's name is the computer name unless the
/// person renamed it in Settings > Devices.
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
            stopHub(endingSessions: false)
        }
        settingsModel.thisDeviceRenamed = { [weak pages] name in pages?.store.setHubDeviceName(name) }
    }

    /// Follows the hub address and the account from now on.
    func start(settings: SettingsController) {
        guard watch == nil else { return }
        let auth = auth
        // task-owner: DeviceHubService.watch: follows deviceHub.url and sign-in for the app's life
        watch = Task { [weak self, weak settings] in
            await auth.awaitRestored()
            await self?.pages.store.load()
            for await (address, user) in ObservationStream({ (Self.address(settings), auth.isSignedIn ? (auth.user?.id ?? "") : nil) }) {
                guard let self else { return }
                url = address.flatMap(URL.init(string:))
                self.user = user
                pages.hubConfigured = url != nil
                reconcile()
            }
        }
    }

    /// `deviceHub.url` as the hub's address; only DEV builds read the setting.
    private static func address(_ settings: SettingsController?) -> String? {
        #if DEBUG
        return settings?.snapshot.deviceHub.baseURL?.absoluteString
        #else
        return nil
        #endif
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
        logger.info("device hub started")
    }

    /// Signed out (or another account, address or a removal): this Mac's
    /// sessions end on the hub (while the hub session still holds), then the
    /// hub stops and Mac Screen forgets it.
    private func stopHub(endingSessions: Bool) {
        guard let hub else { return }
        self.hub = nil
        running = nil
        if endingSessions {
            var ids = Set(hub.tickets.keys)
            if let session = pages.hubHost.session { ids.insert(session.id) }
            // task-owner: one /end per open session before the hub forgets the account
            Task {
                for id in ids { try? await hub.endSession(id, reason: MacScreenHubReason.signedOut.rawValue) }
                hub.stop()
            }
        } else {
            hub.stop()
        }
        pages.hub = nil
        logger.info("device hub stopped")
    }
}

extension AppServices {
    /// The device hub follows `deviceHub.url` and the cmux account.
    func startDeviceHub(_ settings: SettingsController) {
        deviceHub.start(settings: settings)
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
