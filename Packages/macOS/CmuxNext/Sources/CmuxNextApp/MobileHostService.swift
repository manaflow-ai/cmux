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
    private var host: MobileIrxHost?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.mobile")

    /// Starts (or restarts for a new account) the phone listener.
    func start(auth: any MobileHostAuth, launch: LaunchIdentity, daemon: DaemonService) {
        let previous = host
        guard let configuration = Self.configuration(launch: launch, daemon: daemon) else {
            logger.error("phone access disabled: no v2 control-plane URL for this environment")
            return
        }
        let host = MobileIrxHost(configuration: configuration, auth: auth, makeBackend: { @MainActor in
            let endpoint = try await daemon.endpoint()
            return try await DaemonCompatBackend.connect(endpointProvider: { endpoint })
        })
        self.host = host
        Task { [logger] in
            await previous?.stop()
            await host.start()
            let phase = await host.phase
            logger.info("phone access: \(String(describing: phase), privacy: .public)")
        }
    }

    func stop() {
        let host = host
        self.host = nil
        Task { await host?.stop() }
    }

    static func configuration(launch: LaunchIdentity, daemon: DaemonService,
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
            displayName: Host.current().localizedName ?? "Mac",
            appVersion: info["CFBundleShortVersionString"] as? String ?? "0",
            appBuild: info["CFBundleVersion"] as? String ?? "0",
            daemonSocketPath: { @MainActor in try? await daemon.endpoint().socketPath })
    }
}
