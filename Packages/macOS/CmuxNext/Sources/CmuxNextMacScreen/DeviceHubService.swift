import AppKit
public import CmuxNextCompat
import CmuxNextControl
import CmuxNextDevices
public import CmuxNextSettings
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
public final class DeviceHubService {
    /// The cmux account the hub follows (the App's sign-in).
    public struct Account {
        /// Returns once the saved sign-in is restored at launch.
        public var awaitRestored: @MainActor () async -> Void
        /// The signed-in user's id ("" when unknown), nil when signed out;
        /// read inside an observation, so a sign-in or out is seen.
        public var userID: @MainActor () -> String?
        /// The account's access token for the hub.
        public var accessToken: @Sendable () async throws -> String

        public init(awaitRestored: @escaping @MainActor () async -> Void, userID: @escaping @MainActor () -> String?,
                    accessToken: @escaping @Sendable () async throws -> String) {
            self.awaitRestored = awaitRestored
            self.userID = userID
            self.accessToken = accessToken
        }
    }

    private let pages: MacScreenPages
    private let account: Account
    private let bundleIdentifier: String
    /// The app's one guard of the Keychain UI switch (the hub's identity and relay secrets).
    private let loginKeychain: LoginKeychain
    /// Settings > Devices (the React page's `devices` card).
    public let settingsModel: MacScreenDevicesSettings
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
    /// Loads this Mac's identity off the main thread, then installs the hub.
    private var loading: Task<Void, Never>?
    /// What `loading` is making a hub for.
    private var loadingFor: (url: URL, user: String)?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "device-hub")

    public init(pages: MacScreenPages, account: Account, bundleIdentifier: String?, loginKeychain: LoginKeychain) {
        self.pages = pages
        self.account = account
        self.loginKeychain = loginKeychain
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
    public func start(settings: SettingsController) {
        guard watch == nil else { return }
        let account = account
        // task-owner: DeviceHubService.watch: follows deviceHub.url and sign-in for the app's life
        watch = Task { [weak self] in
            await account.awaitRestored()
            await self?.pages.store.load()
            for await (address, user) in ObservationStream({ (Self.address(settings), account.userID()) }) {
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
        if let loadingFor, loadingFor.url == url, loadingFor.user == user { return }
        stopHub(endingSessions: true)
        startHub(url: url, user: user)
    }

    /// Loads the identity (file Keychain, Secure Enclave) off the main thread,
    /// then installs the hub unless a stop or another start came first.
    private func startHub(url: URL, user: String) {
        let token = account.accessToken, bundleIdentifier = bundleIdentifier, loginKeychain = loginKeychain
        let name = pages.store.hubDeviceName ?? MacScreenShareHost.computerName
        loadingFor = (url, user)
        // task-owner: DeviceHubService.loading: one identity load; stopHub cancels it
        loading = Task { [weak self] in
            let hub: DeviceHub
            do {
                hub = try await DeviceHub.forApp(baseURL: url, bundleIdentifier: bundleIdentifier, deviceName: name,
                                                 tokens: DeviceHubAccountToken(token), loginKeychain: loginKeychain)
            } catch {
                guard let self, !Task.isCancelled else { return }
                logger.error("device hub identity unavailable: \(String(describing: error), privacy: .public)")
                loadingFor = nil
                loading = nil
                return
            }
            guard let self, !Task.isCancelled, let loadingFor, loadingFor.url == url, loadingFor.user == user else { return }
            self.loadingFor = nil
            loading = nil
            install(hub, url: url, user: user)
        }
    }

    private func install(_ hub: DeviceHub, url: URL, user: String) {
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
    public func willSignOut() {
        stopHub(endingSessions: true)
    }

    /// Signed out (or another account, address or a removal): this Mac's
    /// sessions end here at once, and the hub hears why in the background
    /// (one device sign-out, `signed_out`, while the hub session still
    /// holds), then stops. Nothing here waits on the network: the main
    /// actor stays free. `removed`: another device (or this one) removed
    /// this Mac, so its sessions end with that reason, never "signed out".
    private func stopHub(endingSessions: Bool, removed: Bool = false) {
        loading?.cancel()
        loading = nil
        loadingFor = nil
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
