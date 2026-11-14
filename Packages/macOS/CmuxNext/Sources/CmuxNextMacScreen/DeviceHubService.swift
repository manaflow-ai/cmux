import AppKit
import CCmuxDaemonConnFFI
public import CmuxNextCompat
import CmuxNextControl
public import CmuxNextDevices
public import CmuxNextSettings
public import Foundation
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

    /// Platform identity loader; injected so callers can supply their own key store.
    public typealias AppHubFactory = @MainActor (URL, String, String, DeviceHubAccountToken, LoginKeychain) async throws -> DeviceHub
    private let makeAppHub: AppHubFactory
    private let retryClock: any Clock<Duration>
    private let pages: MacScreenPages
    private let account: Account
    private let bundleIdentifier: String
    private let selectedBaseURL: URL?
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
    private var loadingID: UUID?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "device-hub")
    /// cmux Remote serves this Mac (docs/cmux-remote.md): the hub for an address and account,
    /// with the worker's device identity and push relay, or nil to use this app's own. The App sets it.
    public var makeRemoteHub: (@MainActor (URL, String) async -> DeviceHub?)?
    /// The running hub, its account and address after every change (the App anchors cmux Remote).
    public var hubChanged: (@MainActor (DeviceHub?, String?, URL?) -> Void)?

    public init(pages: MacScreenPages, account: Account, bundleIdentifier: String?, loginKeychain: LoginKeychain, selectedBaseURL: URL? = nil,
                retryClock: any Clock<Duration> = ContinuousClock(), makeAppHub: AppHubFactory? = nil) {
        self.retryClock = retryClock
        self.makeAppHub = makeAppHub ?? { url, bundle, name, tokens, keychain in
            try await DeviceHub.forApp(baseURL: url, bundleIdentifier: bundle, deviceName: name,
                                      tokens: tokens, loginKeychain: keychain)
        }
        self.selectedBaseURL = selectedBaseURL
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

    nonisolated deinit {
        loading?.cancel()
        watch?.cancel()
        removalWatch?.cancel()
    }

    /// Follows the hub address and the account from now on.
    public func start(settings: SettingsController) {
        guard watch == nil else { return }
        let account = account, selectedBaseURL = selectedBaseURL
        // task-owner: DeviceHubService.watch: follows deviceHub.url and sign-in for the app's life
        watch = Task { [weak self] in
            await account.awaitRestored()
            await self?.pages.store.load()
            for await (address, user) in ObservationStream({ (selectedBaseURL ?? Self.address(settings), account.userID()) }) {
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
        let id = UUID()
        loadingFor = (url, user)
        loadingID = id
        let makeRemoteHub = makeRemoteHub, makeAppHub = makeAppHub, clock = retryClock
        // task-owner: DeviceHubService.loading: identity attempts and backoff; stopHub cancels both
        loading = Task { [weak self] in
            // Rust owns exponential spacing and jitter. Identity availability has no change event:
            // one retry per capped delay continues until success, sign-out, removal or replacement.
            var retry = cmux_retry_pacer_new(cmux_retry_policy_new(1_000_000_000, 30_000_000_000, 10, 0, true))
            // wakeup-allow: every failed identity attempt suspends for Rust backoff (at least 0.8s); success/cancellation exits; no identity-ready event exists.
            while !Task.isCancelled, self?.loadingID == id {
                do {
                    let remote = await makeRemoteHub?(url, user)
                    guard !Task.isCancelled, self?.loadingID == id else { return }
                    let hub: DeviceHub
                    if let remote { hub = remote } else {
                        hub = try await makeAppHub(url, bundleIdentifier, name, DeviceHubAccountToken(token), loginKeychain)
                    }
                    guard let self, !Task.isCancelled, loadingID == id else { return }
                    hub.deviceName = name
                    loadingFor = nil
                    loadingID = nil
                    loading = nil
                    pages.hubStartupError = nil
                    install(hub, url: url, user: user)
                    return
                } catch {
                    guard !Task.isCancelled, self?.loadingID == id else { return }
                    let code = Self.startupError(error)
                    self?.pages.hubStartupError = code
                    self?.logger.error("device hub identity unavailable: \(code, privacy: .public)")
                }
                let delay = cmux_retry_pacer_failed(&retry, Double.random(in: 0..<1))
                guard delay >= 0 else { return }
                // wakeup-allow: cancellable backoff after an actual platform failure, paced by Rust and capped at 30s; no polling for readiness.
                do { try await clock.sleep(for: .nanoseconds(delay)) } catch { return }
            }
        }
    }

    /// Platform error codes only: diagnostics must never include tokens or key material.
    private static func startupError(_ error: any Error) -> String {
        switch error as? DeviceIdentity.Failure {
        case .secureEnclaveUnavailable: return "device_identity_secure_enclave_unavailable"
        case let .keychain(status): return "device_identity_keychain_\(status)"
        case .corruptKeyBlob: return "device_identity_corrupt_key_blob"
        case nil: return "device_identity_unavailable"
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
        hubChanged?(hub, user, url)
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
        loadingID = nil
        pages.hubStartupError = nil
        removalWatch?.cancel()
        removalWatch = nil
        guard let hub else { return }
        self.hub = nil
        running = nil
        hubChanged?(nil, nil, nil)
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
