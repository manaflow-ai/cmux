import AppKit
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextMobile
import CmuxNextSettings
import Foundation
import os

/// Phone access for this Mac (plans/cmux-next/cloud-ios.md): the irx host
/// with the v2 same-account gate, the mobile.* compat adapter for shipped
/// iOS builds, and daemon lanes for new ones. It starts only once a signed-in
/// account is supplied (`start(auth:)`) and phone access is on
/// (`phone.allowConnections`, `setAllowed`); the host itself never reads
/// tokens from disk. This and `MobileIrxHost` are the only Iroh-aware parts:
/// the settings and their rules (`PhoneAccessGate`) name no transport.
final class MobileHostService {
    private(set) var host: MobileIrxHost?
    private var starting: Task<Void, Never>?
    /// Bumped by every start and stop; a start that lost the race drops out.
    private var generation = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.mobile")
    /// Where usable phone connections are reported (`mobile.rpc.ready` on
    /// the control socket's event stream); set once the socket starts.
    let readiness = MobileReadinessRelay()

    /// What phones may do here; the host reads it per request (`phone.startSessions`).
    let access = PhoneAccessGate()
    /// `phone.allowConnections`: the listener runs only while this is on.
    private(set) var allowed = false
    /// The signed-in account the listener registers under, while there is one.
    private var account: (auth: any MobileHostAuth, launch: LaunchIdentity, daemon: DaemonService)?
    private var follower: PhoneAccessFollower?
    /// The allowed phones and the question for new ones (`phone.newDevices`); set by `follow`.
    private(set) var admission: PhoneAdmission?
    /// Phones can reach this Mac: signed in and allowed (the phone keep-awake reason).
    var isServing: Bool { allowed && account != nil }

    /// The account to serve phones for (sign-in, or a user or team switch). The
    /// listener starts now when phone access is on, else when it is turned on.
    func start(auth: any MobileHostAuth, launch: LaunchIdentity, daemon: DaemonService) {
        account = (auth, launch, daemon)
        allowed ? startHost(auth: auth, launch: launch, daemon: daemon) : stopHost()
        servingChanged()
    }

    /// Signed out, or the app quits: no account, no listener.
    func stop() {
        account = nil
        stopHost()
        servingChanged()
    }

    /// Settings > Accounts > Phone Access turned the listener on or off.
    func setAllowed(_ on: Bool) {
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
    func follow(_ settings: SettingsController, launch: LaunchIdentity) {
        guard follower == nil else { return }
        let directory = Self.stateDirectory(namespace: Self.namespace(launch))
        let admission = PhoneAdmission(store: PhoneDeviceStore(directory: directory))
        self.admission = admission
        access.setAdmission { device in await admission.decide(device) }
        follower = PhoneAccessFollower(mobile: self, settings: settings, history: MobileHostHistory(stateDirectory: directory))
        follower?.start()
    }

    /// Settings > Accounts > Phone Access: Remove. The phone leaves the allowed list and its open
    /// sessions close now; its next connection asks again.
    func removePhone(_ id: String) {
        admission?.remove(id)
        let host = host
        // task-owner: one hop to the host actor; disconnect is idempotent
        Task { await host?.disconnect(deviceID: id) }
    }

    private func servingChanged() {
        KeepAwakeService.shared.setPhoneServing(isServing)
    }

    /// Starts (or restarts for a new account) the phone listener. The Mac's
    /// display name is read off the main actor first (`MacName`).
    private func startHost(auth: any MobileHostAuth, launch: LaunchIdentity, daemon: DaemonService) {
        generation += 1
        let current = generation
        let previous = host
        host = nil
        starting?.cancel()
        let access = access
        starting = Task { [weak self, logger] in
            await previous?.stop()
            let displayName = await MacName.computerName()
            guard let self, self.generation == current, !Task.isCancelled else { return }
            guard let configuration = Self.configuration(launch: launch, daemon: daemon, displayName: displayName) else {
                logger.error("phone access disabled: no v2 control-plane URL for this environment")
                return
            }
            let readiness = self.readiness
            let host = MobileIrxHost(configuration: configuration, auth: auth, makeBackend: { @MainActor in
                let endpoint = try await daemon.endpoint()
                return try await DaemonCompatBackend.connect(endpointProvider: { endpoint })
            }, access: access, onUsable: { readiness.report($0) })
            self.host = host
            await host.start()
            let phase = await host.phase
            logger.info("phone access: \(String(describing: phase), privacy: .public)")
        }
    }

    private func stopHost() {
        generation += 1
        starting?.cancel()
        starting = nil
        let host = host
        self.host = nil
        // task-owner: teardown hop; MobileIrxHost.stop() is idempotent and bumps its lifetime
        Task { await host?.stop() }
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
