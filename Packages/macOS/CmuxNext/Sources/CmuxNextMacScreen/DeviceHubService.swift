import AppKit
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDevices
public import CmuxNextSettings
public import CmuxNextWakeups
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
    /// Waits for the restored sign-in and the saved names, then starts ``follow``.
    private var watch: Task<Void, Never>?
    /// Follows the hub address and the account (a service: it starts and stops the hub whatever shows).
    private var follow: ServiceObservation<Target>?
    /// Follows the running hub's socket: another device removed this Mac.
    private var removalWatch: ServiceObservation<Bool>?
    /// Loads this Mac's identity off the main thread, then installs the hub.
    private var loading: Task<Void, Never>?
    /// What `loading` is making a hub for.
    private var loadingFor: (url: URL, user: String)?
    /// The identity load out now: every start and stop moves it on, so a load that lands after a stop (or a
    /// newer start for the same account) installs nothing; read on main, in the turn that applies it.
    private var loadGeneration: UInt64 = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "device-hub")
    /// The app's Energy Saver policy, which holds the hub socket's ping while the Mac sleeps and
    /// reconnects it once after a wake; nil keeps it always awake.
    private let energy: EnergyPolicySource?

    public init(pages: MacScreenPages, account: Account, bundleIdentifier: String?, energy: EnergyPolicySource? = nil) {
        self.pages = pages
        self.account = account
        self.energy = energy
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

    /// ``start(settings:)`` ran.
    public var isStarted: Bool { watch != nil }

    /// What the hub is made for: its address and the signed-in account.
    private struct Target: Equatable {
        var url: URL?
        var user: String?
    }

    /// Follows the hub address and the account from now on.
    public func start(settings: SettingsController) {
        guard watch == nil else { return }
        let restored = account.awaitRestored, store = pages.store, work = pages.mainWork
        // task-owner: DeviceHubService.watch: one wait for the restored sign-in and the saved names (each its
        // owner's main-actor call), then the follow starts in one visible task (the home page says whether this
        // Mac is signed in).
        watch = Task { @concurrent [weak self] in
            await restored()
            await store.load()
            await work.apply(.visible, owner: "DeviceHubService.follow") { [weak self] () -> Void in
                self?.followAccount(settings)
            }
        }
    }

    /// `visible`: a sign-in or an address change shows on Mac Screen's home page; a person's sign-in flushes as
    /// the rest of their action.
    private func followAccount(_ settings: SettingsController) {
        let userID = account.userID
        follow = ServiceObservation(.visible, owner: "DeviceHubService.account", on: pages.mainWork) {
            Target(url: Self.address(settings), user: userID())
        } apply: { [weak self] target in
            guard let self else { return }
            url = target.url
            user = target.user
            pages.hubConfigured = target.url != nil
            reconcile()
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
        let tokens = DeviceHubAccountToken(account.accessToken), bundleIdentifier = bundleIdentifier, energy = energy
        let work = pages.mainWork
        let name = pages.store.hubDeviceName ?? MacScreenShareHost.computerName
        loadingFor = (url, user)
        loadGeneration &+= 1
        let generation = loadGeneration
        // task-owner: DeviceHubService.loading: one identity load (the hub loads it off main); stopHub cancels it.
        // The result lands in one visible task: the hub's devices show on Mac Screen's home page.
        loading = Task { @concurrent [weak self] in
            let made: Result<DeviceHub, DeviceHubError>
            do {
                made = .success(try await DeviceHub.forApp(baseURL: url, bundleIdentifier: bundleIdentifier, deviceName: name,
                                                           tokens: tokens, energy: energy))
            } catch {
                made = .failure(error as? DeviceHubError ?? .identity("\(error)"))
            }
            await work.apply(.visible, owner: "DeviceHubService.loaded") { [weak self] () -> Void in
                self?.loaded(made, url: url, user: user, generation: generation)
            }
        }
    }

    /// The identity load ended: installs the hub unless a stop or another start came first.
    private func loaded(_ made: Result<DeviceHub, DeviceHubError>, url: URL, user: String, generation: UInt64) {
        guard generation == loadGeneration else { return }
        self.loadingFor = nil
        loading = nil
        switch made {
        case let .success(hub):
            install(hub, url: url, user: user)
        case let .failure(error):
            logger.error("device hub identity unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    private func install(_ hub: DeviceHub, url: URL, user: String) {
        self.hub = hub
        running = (url, user)
        pages.hub = hub
        // task-owner: one registration and socket start; stop() cancels the socket. Off main: start is the hub's
        // own main-actor call.
        Task { @concurrent in await hub.start() }
        // Another device removed this Mac: it leaves the hub until the person signs in again. `automation`:
        // another device's change, and the stop still runs while nothing shows.
        removalWatch = ServiceObservation(.automation, owner: "DeviceHubService.removal", on: pages.mainWork) {
            hub.connection == .removed
        } apply: { [weak self] removed in
            guard removed, let self, self.hub === hub else { return }
            leftHub = true
            stopHub(endingSessions: false, removed: true)
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
        loadGeneration &+= 1
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
        let work = pages.mainWork, reason = MacScreenHubReason.signedOut.rawValue
        // task-owner: the sign-out call (an older hub: one /end per session), each the hub's own main-actor
        // request, then the stop in one background task: nobody waits on it, this Mac's sessions already ended.
        Task { @concurrent in
            do { try await hub.signOutDevice() } catch {
                await withTaskGroup(of: Void.self) { group in
                    for id in ids {
                        group.addTask { try? await hub.endSession(id, reason: reason) }
                    }
                }
            }
            await work.apply(.background, owner: "DeviceHubService.signedOut") { () -> Void in hub.stop() }
        }
        logger.info("device hub signing out")
    }
}
