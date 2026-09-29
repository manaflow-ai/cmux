import AppKit
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextMobile
import Foundation
import os

/// Phone access for this Mac (plans/cmux-next/cloud-ios.md): the irx host
/// with the v2 same-account gate, the mobile.* compat adapter for shipped
/// iOS builds, and daemon lanes for new ones. It starts only once a signed-in
/// account is supplied (`start(auth:)`); the host itself never reads tokens
/// from disk.
final class MobileHostService {
    private(set) var host: MobileIrxHost?
    private var starting: Task<Void, Never>?
    /// Bumped by every start and stop; a start that lost the race drops out.
    private var generation = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.mobile")
    /// Where usable phone connections are reported (`mobile.rpc.ready` on
    /// the control socket's event stream); set once the socket starts.
    let readiness = MobileReadinessRelay()

    /// Starts (or restarts for a new account) the phone listener. The Mac's
    /// display name is read off the main actor first (`MacName`).
    func start(auth: any MobileHostAuth, launch: LaunchIdentity, daemon: DaemonService) {
        generation += 1
        let current = generation
        let previous = host
        host = nil
        starting?.cancel()
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
            }, onUsable: { readiness.report($0) })
            self.host = host
            await host.start()
            let phase = await host.phase
            logger.info("phone access: \(String(describing: phase), privacy: .public)")
        }
    }

    func stop() {
        generation += 1
        starting?.cancel()
        starting = nil
        let host = host
        self.host = nil
        Task { await host?.stop() }
    }

    static func configuration(launch: LaunchIdentity, daemon: DaemonService, displayName: String,
                              environment: [String: String] = ProcessInfo.processInfo.environment)
        -> MobileHostConfiguration? {
        let namespace = launch.bundleID ?? "com.cmuxterm.app.next"
        #if DEBUG
        let fallback = "development"
        let keyStorage = MobileHostConfiguration.KeyStorage.files
        #else
        let fallback = namespace.contains("staging") ? "staging" : "production"
        let keyStorage = MobileHostConfiguration.KeyStorage.keychain
        #endif
        let name = environment["CMUX_IROH_V2_ENVIRONMENT"].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        guard let baseURL = MobileHostConfiguration.baseURL(environment: name) else { return nil }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let info = Bundle.main.infoDictionary ?? [:]
        return MobileHostConfiguration(
            baseURL: baseURL, environment: name, namespace: namespace, tag: launch.tag ?? "default",
            stateDirectory: support.appendingPathComponent(namespace, isDirectory: true), keyStorage: keyStorage,
            displayName: displayName,
            appVersion: info["CFBundleShortVersionString"] as? String ?? "0",
            appBuild: info["CFBundleVersion"] as? String ?? "0",
            daemonSocketPath: { @MainActor in try? await daemon.endpoint().socketPath })
    }
}
