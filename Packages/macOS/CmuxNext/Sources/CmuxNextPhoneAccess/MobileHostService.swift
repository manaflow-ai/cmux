public import CmuxNextControl
import CmuxNextDaemon
public import CmuxNextDaemonService
import CmuxNextKeepAwake
public import CmuxNextMobile
public import CmuxNextSettings
import Foundation
import os

/// Phone access for this Mac (plans/cmux-next/cloud-ios.md): the irx host
/// with the v2 same-account gate, the mobile.* compat adapter for shipped
/// iOS builds, and daemon lanes for new ones. It starts only once a signed-in
/// account is supplied (`start(auth:)`) and phone access is on
/// (`phone.allowConnections`, `setAllowed`); the host itself never reads
/// tokens from disk. This and `MobileIrxHost` are the only Iroh-aware parts:
/// the settings and their rules (`PhoneAccessGate`) name no transport.
public final class MobileHostService {
    public private(set) var host: MobileIrxHost?
    private var starting: Task<Void, Never>?
    /// The last listener's teardown; the next listener starts only after it ends, so a quick
    /// sign-out and sign-in or off and on never leaves an old phone link open beside the new one.
    private var stopping: Task<Void, Never>?
    /// Bumped by every start and stop; a start that lost the race drops out.
    private var generation = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.mobile")
    /// Where usable phone connections are reported (`mobile.rpc.ready` on
    /// the control socket's event stream); set once the socket starts.
    public let readiness = MobileReadinessRelay()
    /// The listener's phase and its usable phones (the Mobile Pairing page).
    public let status = MobileHostStatus()
    /// Copies the current listener's phase into ``status``; replaced with the listener.
    private var phaseFollower: Task<Void, Never>?
    /// Whether a signed-in account is set (``start(auth:launch:daemon:)``).
    public var hasAccount: Bool { account != nil }
    /// This Mac's user-visible name, read off the main actor (the App's `MacName`).
    private let displayName: @Sendable () async -> String

    /// What phones may do here; the host reads it per request (`phone.startSessions`).
    public let access = PhoneAccessGate()
    /// `phone.allowConnections`: the listener runs only while this is on.
    public private(set) var allowed = false
    /// The signed-in account the listener registers under, while there is one.
    private var account: (auth: any MobileHostAuth, launch: LaunchIdentity, daemon: DaemonService)?
    private var follower: PhoneAccessFollower?
    /// Phones can reach this Mac: signed in and allowed (the phone keep-awake reason).
    var isServing: Bool { allowed && account != nil }

    public init(displayName: @escaping @Sendable () async -> String) {
        self.displayName = displayName
    }

    /// The account to serve phones for (sign-in, or a user or team switch). The
    /// listener starts now when phone access is on, else when it is turned on.
    public func start(auth: any MobileHostAuth, launch: LaunchIdentity, daemon: DaemonService) {
        account = (auth, launch, daemon)
        allowed ? startHost(auth: auth, launch: launch, daemon: daemon) : stopHost()
        servingChanged()
    }

    /// Signed out, or the app quits: no account, no listener.
    public func stop() {
        account = nil
        stopHost()
        servingChanged()
    }

    /// Settings > Accounts > Phone Access turned the listener on or off.
    public func setAllowed(_ on: Bool) {
        guard on != allowed else { return }
        allowed = on
        if on, let account {
            startHost(auth: account.auth, launch: account.launch, daemon: account.daemon)
        } else if !on {
            stopHost()
        }
        servingChanged()
    }

    /// Follows Settings > Accounts > Phone Access from now on (once).
    public func follow(_ settings: SettingsController, launch: LaunchIdentity,
                       configureAdmission: (@MainActor (PhoneAccessGate, @escaping @Sendable (String) async -> Void) -> Void)? = nil) {
        guard follower == nil else { return }
        configureAdmission?(access, { [weak self] id in await self?.disconnectPhone(id) })
        follower = PhoneAccessFollower(mobile: self, settings: settings,
                                       history: MobileHostHistory(stateDirectory: Self.stateDirectory(namespace: Self.namespace(launch))))
        follower?.start()
    }

    public func disconnectPhone(_ endpoint: String) async {
        await host?.disconnectPhone(endpoint)
    }

    private func servingChanged() {
        KeepAwakeService.shared.setPhoneServing(isServing)
        access.setServing(isServing)
    }

    /// Starts (or restarts for a new account) the phone listener. The Mac's
    /// display name is read off the main actor first (`displayName`).
    private func startHost(auth: any MobileHostAuth, launch: LaunchIdentity, daemon: DaemonService) {
        generation += 1
        let current = generation
        starting?.cancel()
        phaseFollower?.cancel()
        status.reset()
        let teardown = retireHost()
        let access = access
        let status = status
        starting = Task { [weak self, logger] in
            await teardown.value
            let displayName = await self?.displayName() ?? "Mac"
            guard let self, self.generation == current, !Task.isCancelled else { return }
            guard let configuration = Self.configuration(launch: launch, daemon: daemon, displayName: displayName) else {
                logger.error("phone access disabled: no v2 control-plane URL for this environment")
                return
            }
            let readiness = self.readiness
            let host = MobileIrxHost(configuration: configuration, auth: auth, makeBackend: { @MainActor in
                let endpoint = try await daemon.endpoint()
                return try await DaemonCompatBackend.connect(endpointProvider: { endpoint })
            }, access: access, onUsable: { session in
                readiness.report(session)
                let now = Date()
                // task-owner: one main-actor hop per usable phone connection; ends at once
                Task { @MainActor in status.phoneBecameUsable(at: now) }
            })
            self.host = host
            // task-owner: lives as long as this listener; stopHost/startHost cancel it
            self.phaseFollower = Task { @MainActor [status] in
                for await phase in await host.phaseUpdates() {
                    guard !Task.isCancelled else { return }
                    status.phase = phase
                }
            }
            await host.start()
            let phase = await host.phase
            logger.info("phone access: \(String(describing: phase), privacy: .public)")
        }
    }

    private func stopHost() {
        generation += 1
        starting?.cancel()
        starting = nil
        phaseFollower?.cancel()
        phaseFollower = nil
        status.reset()
        _ = retireHost()
    }

    /// Stops the current listener after every earlier teardown, and records that in `stopping`, so
    /// a start cancelled by a quicker one still leaves its old listener's stop for the next to await.
    private func retireHost() -> Task<Void, Never> {
        let host = host
        self.host = nil
        let previous = stopping
        // task-owner: teardown hop, kept in `stopping`; MobileIrxHost.stop() is idempotent and bumps its lifetime
        let teardown = Task {
            await previous?.value
            await host?.stop()
        }
        stopping = teardown
        return teardown
    }

    static func configuration(launch: LaunchIdentity, daemon: DaemonService, displayName: String,
                              environment: [String: String] = ProcessInfo.processInfo.environment)
        -> MobileHostConfiguration? {
        let namespace = Self.namespace(launch)
        #if DEBUG
        let fallback = "development"
        let keyStorage = MobileHostConfiguration.KeyStorage.files
        #else
        let fallback = namespace.contains("staging") ? "staging" : "production"
        let keyStorage = MobileHostConfiguration.KeyStorage.keychain
        #endif
        let name = environment["CMUX_IROH_V2_ENVIRONMENT"].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        guard let baseURL = MobileHostConfiguration.baseURL(environment: name) else { return nil }
        let info = Bundle.main.infoDictionary ?? [:]
        return MobileHostConfiguration(
            baseURL: baseURL, environment: name, namespace: namespace, tag: launch.tag ?? "default",
            stateDirectory: stateDirectory(namespace: namespace), keyStorage: keyStorage,
            displayName: displayName,
            appVersion: info["CFBundleShortVersionString"] as? String ?? "0",
            appBuild: info["CFBundleVersion"] as? String ?? "0",
            daemonSocketPath: { @MainActor in try? await daemon.endpoint().socketPath })
    }

    /// The bundle id the v2 device identity is keyed on.
    static func namespace(_ launch: LaunchIdentity) -> String {
        launch.bundleID ?? "com.cmuxterm.app.next"
    }

    /// Where this bundle's phone host keeps its device keys and cache.
    static func stateDirectory(namespace: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(namespace, isDirectory: true)
    }
}
