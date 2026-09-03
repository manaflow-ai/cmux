import Foundation
import NetworkExtension
import OSLog
import Security
import SystemExtensions

private let tunnelExtensionLog = Logger(subsystem: "com.cmuxterm.app", category: "CloudTunnel")

/// Owns the app-managed half of the Cloud VM tunnel: activating the bundled
/// packet-tunnel system extension, and configuring and starting the VPN it
/// backs.
///
/// Only constructible from a `VMTunnelBackendSelection` that actually resolved
/// to `.networkExtension`, so nothing here can run against a build with no
/// provider to talk to. When the selection is `.wgQuick`, `cmux vpn up` keeps
/// shelling out to `sudo wg-quick` and this type is never instantiated.
///
/// Outside the Mac App Store the provider must be a *system* extension, which
/// means the user approves it once in System Settings and the app must be in
/// `/Applications` for macOS to accept the activation request at all.
final class VMTunnelExtensionController {
    /// Where the tunnel is in its lifecycle. Surfaced verbatim over the socket
    /// so `cmux vpn up` and the sidebar say the same thing.
    enum ActivationState: String, Equatable, Sendable {
        /// macOS is waiting for the user to approve the extension in System
        /// Settings › General › Login Items & Extensions.
        case awaitingUserApproval = "awaiting-user-approval"
        /// A replacement was staged but takes effect after a restart.
        case awaitingReboot = "awaiting-reboot"
        case active
    }

    enum ControllerError: Error, CustomStringConvertible {
        case notInApplicationsFolder(String)
        case activationFailed(String)
        case privateKeyUnavailable(String)
        case keychainFailed(OSStatus)
        case managerUnavailable(String)
        case backendUnavailable(VMTunnelBackendSelection.UnavailableReason?)

        var description: String {
            switch self {
            case .notInApplicationsFolder(let path):
                return "macOS only loads a system extension from an app in /Applications; this build runs from \(path)."
            case .activationFailed(let detail):
                return "The cmux VPN extension could not be activated: \(detail)"
            case .privateKeyUnavailable(let detail):
                return "This Mac's tunnel key is not readable: \(detail)"
            case .keychainFailed(let status):
                return "Storing the tunnel key in the keychain failed (OSStatus \(status))."
            case .managerUnavailable(let detail):
                return "The cmux VPN configuration could not be saved: \(detail)"
            case .backendUnavailable(let reason):
                switch reason {
                case .entitlementMissing:
                    return "This build carries no packet-tunnel entitlement, so the app cannot manage the tunnel. Use `sudo wg-quick up`."
                case .providerNotBundled:
                    return "This build embeds no packet-tunnel system extension, so the app cannot manage the tunnel. Use `sudo wg-quick up`."
                case nil:
                    return "The app-managed tunnel is unavailable on this build. Use `sudo wg-quick up`."
                }
            }
        }
    }

    let providerBundleIdentifier: String
    private let appBundleURL: URL
    private let requestQueue = DispatchQueue(label: "com.cmuxterm.app.tunnel-extension")
    private let stateLock = NSLock()
    /// `OSSystemExtensionRequest.delegate` is weak, and approval arrives as a
    /// second callback minutes after the first. Holding the delegate here keeps
    /// it alive past `activate()`'s return so `onStateChange` still reports the
    /// eventual `.active`; without this the request is silently orphaned the
    /// moment the user is asked to approve.
    private var activationDelegate: ActivationDelegate?

    init?(selection: VMTunnelBackendSelection, appBundleURL: URL = Bundle.main.bundleURL) {
        guard selection.backend == .networkExtension,
              let identifier = selection.providerBundleIdentifier else { return nil }
        self.providerBundleIdentifier = identifier
        self.appBundleURL = appBundleURL
    }

    /// Whether macOS will even consider loading this app's system extension.
    ///
    /// A system extension is only loaded from an app inside `/Applications`.
    /// Reporting that up front turns a silent, permanent activation failure
    /// into an actionable message — the single most common way this path fails
    /// for a user who runs cmux from `~/Downloads`.
    static func appLocationSupportsSystemExtension(_ bundleURL: URL) -> Bool {
        let path = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix("/Applications/")
    }

    // MARK: - System extension activation

    /// Submit an activation request and return the first outcome macOS reports.
    ///
    /// `requestNeedsUserApproval` and `didFinishWithResult` are separate
    /// callbacks that can arrive minutes apart (the second only after the user
    /// clicks Allow), so this resolves on whichever comes first and reports
    /// later transitions through `onStateChange`. Nothing here polls or sleeps:
    /// every transition is a delegate callback.
    func activate(onStateChange: (@Sendable (ActivationState) -> Void)? = nil) async throws -> ActivationState {
        guard Self.appLocationSupportsSystemExtension(appBundleURL) else {
            throw ControllerError.notInApplicationsFolder(appBundleURL.path)
        }
        let delegate = ActivationDelegate(onStateChange: onStateChange)
        stateLock.lock()
        activationDelegate = delegate
        stateLock.unlock()
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: providerBundleIdentifier,
            queue: requestQueue
        )
        request.delegate = delegate
        return try await withCheckedThrowingContinuation { continuation in
            delegate.attach(continuation)
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    // MARK: - VPN configuration

    /// Create or update this Mac's cmux VPN configuration and start it.
    ///
    /// `privateKey` is written to the keychain and passed to the provider as a
    /// `passwordReference`; it is never put in `providerConfiguration`, which
    /// macOS persists in the system VPN preferences.
    func startTunnel(
        configuration: VMTunnelConfiguration,
        privateKey: String,
        interfaceName: String,
        configDigest: String?,
        onDemandEnabled: Bool = true
    ) async throws {
        let passwordReference = try storePrivateKey(privateKey, interfaceName: interfaceName)
        let manager = try await loadOrCreateManager()

        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleIdentifier
        proto.serverAddress = configuration.serverAddress ?? interfaceName
        proto.passwordReference = passwordReference
        var providerConfiguration = configuration.providerConfiguration
        providerConfiguration["interface_name"] = interfaceName
        if let configDigest { providerConfiguration["config_digest"] = configDigest }
        proto.providerConfiguration = providerConfiguration

        manager.protocolConfiguration = proto
        manager.localizedDescription = String(
            localized: "cloud.tunnel.vpnName",
            defaultValue: "cmux Cloud VMs"
        )
        manager.isEnabled = true
        // On-demand scoped to the private network's own search domains, not
        // "always on". An unconditional NEOnDemandRuleConnect would reconnect
        // the VPN for every network request the Mac makes, which is why the
        // shipping wg-quick path is manual; matching only the Cloud VM domains
        // is what makes bring-up automatic without hijacking the Mac's routing.
        let domains = configuration.interface.searchDomains
        if onDemandEnabled, !domains.isEmpty {
            let rule = NEOnDemandRuleEvaluateConnection()
            let connectionRule = NEEvaluateConnectionRule(
                matchDomains: domains,
                andAction: .connectIfNeeded
            )
            rule.connectionRules = [connectionRule]
            manager.onDemandRules = [rule]
            manager.isOnDemandEnabled = true
        } else {
            manager.onDemandRules = []
            manager.isOnDemandEnabled = false
        }

        do {
            try await manager.saveToPreferences()
            // Required: a manager must be re-loaded after a save before its
            // connection can be started, or startVPNTunnel throws
            // NEVPNErrorConfigurationInvalid.
            try await manager.loadFromPreferences()
            try manager.connection.startVPNTunnel()
        } catch {
            throw ControllerError.managerUnavailable(error.localizedDescription)
        }
        tunnelExtensionLog.info("started app-managed tunnel for interface \(interfaceName, privacy: .public)")
    }

    func stopTunnel() async throws {
        let managers = try await Self.loadAllManagers()
        for manager in managers where (manager.protocolConfiguration as? NETunnelProviderProtocol)?
            .providerBundleIdentifier == providerBundleIdentifier {
            // Disable on-demand first, or the rules bring the tunnel straight
            // back up after the disconnect.
            if manager.isOnDemandEnabled {
                manager.isOnDemandEnabled = false
                try? await manager.saveToPreferences()
            }
            manager.connection.stopVPNTunnel()
        }
    }

    /// `NEVPNStatus` as the stable string the socket and `cmux vpn status`
    /// print. `NEVPNStatus` is an ObjC enum whose raw values are not a contract
    /// worth exposing over a socket.
    static func statusName(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }

    /// The current VPN status for this provider, or nil when no configuration
    /// exists yet.
    func status() async -> NEVPNStatus? {
        guard let managers = try? await Self.loadAllManagers() else { return nil }
        return managers.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == providerBundleIdentifier
        }?.connection.status
    }

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        let managers: [NETunnelProviderManager]
        do {
            managers = try await Self.loadAllManagers()
        } catch {
            throw ControllerError.managerUnavailable(error.localizedDescription)
        }
        if let existing = managers.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == providerBundleIdentifier
        }) {
            return existing
        }
        return NETunnelProviderManager()
    }

    private static func loadAllManagers() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
    }

    // MARK: - Private key handoff

    static let keychainService = "com.cmuxterm.cloud-tunnel"

    /// Store the tunnel's private key and return the persistent reference the
    /// provider reads it back with.
    ///
    /// The provider is sandboxed and cannot open the app's config file in the
    /// user's home directory, so a shared keychain item is the only handoff
    /// that does not put the key in system preferences.
    private func storePrivateKey(_ privateKey: String, interfaceName: String) throws -> Data {
        guard let data = privateKey.data(using: .utf8) else {
            throw ControllerError.privateKeyUnavailable("the key is not valid UTF-8")
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: interfaceName,
        ]
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecReturnPersistentRef as String] = true
        // The key must be readable while the Mac is locked: the provider can be
        // started by an on-demand rule with no user session in front.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        var result: CFTypeRef?
        let status = SecItemAdd(attributes as CFDictionary, &result)
        guard status == errSecSuccess, let reference = result as? Data else {
            throw ControllerError.keychainFailed(status)
        }
        return reference
    }

    // MARK: - Delegate

    /// Bridges `OSSystemExtensionRequestDelegate`'s callbacks to one
    /// `async` result. Every mutation happens on the request queue macOS calls
    /// back on, and the continuation is resumed exactly once.
    private final class ActivationDelegate: NSObject, OSSystemExtensionRequestDelegate {
        private let onStateChange: (@Sendable (ActivationState) -> Void)?
        private var continuation: CheckedContinuation<ActivationState, Error>?
        private let lock = NSLock()

        init(onStateChange: (@Sendable (ActivationState) -> Void)?) {
            self.onStateChange = onStateChange
            super.init()
        }

        func attach(_ continuation: CheckedContinuation<ActivationState, Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        private func finish(_ result: Result<ActivationState, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            guard let pending else { return }
            switch result {
            case .success(let state): pending.resume(returning: state)
            case .failure(let error): pending.resume(throwing: error)
            }
        }

        func request(
            _ request: OSSystemExtensionRequest,
            actionForReplacingExtension existing: OSSystemExtensionProperties,
            withExtension replacement: OSSystemExtensionProperties
        ) -> OSSystemExtensionRequest.ReplacementAction {
            // Replace unless what is already installed is strictly newer, so a
            // rebuilt extension at the same version still takes effect (the
            // normal case while iterating) without downgrading a user who is
            // ahead of this app.
            let installed = existing.bundleVersion
            let candidate = replacement.bundleVersion
            if installed.compare(candidate, options: .numeric) == .orderedDescending {
                return .cancel
            }
            return .replace
        }

        func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
            tunnelExtensionLog.info("cmux VPN extension is waiting for user approval")
            onStateChange?(.awaitingUserApproval)
            finish(.success(.awaitingUserApproval))
        }

        func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
            let state: ActivationState = result == .willCompleteAfterReboot ? .awaitingReboot : .active
            tunnelExtensionLog.info("cmux VPN extension activation finished: \(state.rawValue, privacy: .public)")
            onStateChange?(state)
            finish(.success(state))
        }

        func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
            tunnelExtensionLog.error("cmux VPN extension activation failed: \(error.localizedDescription, privacy: .public)")
            finish(.failure(ControllerError.activationFailed(error.localizedDescription)))
        }
    }
}

extension VMTunnelExtensionController {
    struct BringUpResult: Sendable {
        let providerBundleIdentifier: String
        let state: ActivationState
        /// False when the extension is not active yet, so nothing was started
        /// and the user still has to approve it.
        let started: Bool
    }

    /// The one app-side path that brings this Mac's tunnel up as a VPN.
    ///
    /// The `vm.tunnel_up` socket verb behind `cmux vpn up` is its only caller
    /// today; a Settings toggle or the Cloud sidebar would call exactly this
    /// rather than repeat the activate-then-start sequence.
    ///
    /// Requires the enrolled config to be on disk already — `vm.tunnel_config`
    /// writes it, and `cmux vpn up` sends that first — so this never enrolls as
    /// a side effect of being asked to connect.
    static func bringUp(
        manager: VMTunnelManager = VMTunnelManager(),
        selection: VMTunnelBackendSelection = .current
    ) async throws -> BringUpResult {
        guard let controller = VMTunnelExtensionController(selection: selection) else {
            throw ControllerError.backendUnavailable(selection.unavailableReason)
        }
        let configuration = try manager.parsedConfiguration()
        let privateKey = try manager.configuredPrivateKey()
        let digest = manager.configDigest()
        // Already connected with these exact config bytes: restarting the VPN
        // would drop every live session for no reason. A digest mismatch means a
        // new enrollment, so that case falls through and re-applies.
        if await controller.status() == .connected, digest != nil, manager.appliedDigest() == digest {
            return BringUpResult(
                providerBundleIdentifier: controller.providerBundleIdentifier,
                state: .active,
                started: true
            )
        }
        let state = try await controller.activate()
        guard state == .active else {
            // Approval or a reboot is pending: starting the VPN now would fail
            // with a provider that is not loaded, so report the state instead
            // of a misleading error.
            return BringUpResult(
                providerBundleIdentifier: controller.providerBundleIdentifier,
                state: state,
                started: false
            )
        }
        try await controller.startTunnel(
            configuration: configuration,
            privateKey: privateKey,
            interfaceName: manager.interfaceName,
            configDigest: digest
        )
        try manager.recordApplied(true, expectedDigest: digest)
        return BringUpResult(
            providerBundleIdentifier: controller.providerBundleIdentifier,
            state: .active,
            started: true
        )
    }

    /// The one app-side path that takes the tunnel down.
    static func takeDown(
        manager: VMTunnelManager = VMTunnelManager(),
        selection: VMTunnelBackendSelection = .current
    ) async throws {
        guard let controller = VMTunnelExtensionController(selection: selection) else {
            throw ControllerError.backendUnavailable(selection.unavailableReason)
        }
        try await controller.stopTunnel()
        try manager.recordApplied(false)
    }
}
