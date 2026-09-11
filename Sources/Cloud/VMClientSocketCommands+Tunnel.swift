import Foundation
import CmuxSettings

/// `vm.tunnel_*`: this Mac's membership in the user's private Cloud VM
/// network. The terminal role uses the user-space hub. `up`, `down`, and
/// `wait` control only the browser Network Extension and fail closed when the
/// signed extension is not available.
///
/// Trust boundary: the completed config never crosses the socket. `tunnel_config`
/// returns only the path of the 0600 file the app wrote, the same boundary every
/// other `vm.` verb already accepts.
///
/// `tunnel_config` and `tunnel_up` are the two verbs that would enroll or
/// touch NetworkExtension, so both ask the coordinator's start policy first
/// (``CloudActivationPolicy``: Cloud Machines on, and a machine exists) and
/// fail closed with the same message the app shows. Status, down, wait, and
/// revoke never start anything and stay available for cleanup.
extension TerminalController {
    nonisolated func socketWorkerCloudTunnelResponse(
        method: String,
        id: Any?,
        params: [String: Any]
    ) -> String? {
        // `DisableCloud`: only the cleanup verbs stay reachable so a managed
        // Mac can still report, stop, and remove tunnel state. Enrollment,
        // `up`, and `wait` fail closed; the coordinator refuses them as well.
        if method.hasPrefix("vm.tunnel_"), ManagedDevicePolicy().isEnforced(.disableCloud) {
            switch method {
            case "vm.tunnel_status", "vm.tunnel_down", "vm.tunnel_revoke":
                break
            default:
                return v2Error(
                    id: id,
                    code: "cloud_disabled",
                    message: String(
                        localized: "cloud.managed.tunnelDisabled",
                        defaultValue: "Cloud private-network access is disabled by your organization."
                    )
                )
            }
        }
        switch method {
        case "vm.tunnel_config":
            // Enrolls the browser role and writes its WireGuard config. The
            // Network Extension consumes it through `vm.tunnel_up`.
            return v2VmCall(id: id) {
                // Fail closed before startup finishes wiring the coordinator,
                // exactly like `vm.tunnel_up`: no admission, no enrollment.
                guard let coordinator = await Self.cloudTunnelCoordinator() else {
                    throw CloudTunnelError.backendUnavailable(.entitlementMissing)
                }
                if let refusal = await coordinator.startRefusal() {
                    throw refusal.error
                }
                let manager = VMTunnelManager()
                let state = try await manager.enroll(client: VMClient.shared)
                // Enrollment is a control-plane round trip; a refusal that
                // landed meanwhile must not leave the written config behind.
                if let refusal = await coordinator.knownStartRefusal() {
                    manager.removeLocalCredentials()
                    throw refusal.error
                }
                var payload = await Self.cloudTunnelStatusPayload(manager: manager)
                payload["tunnel_id"] = state.endpoint.tunnelId
                payload["provider"] = state.endpoint.provider
                payload["address_v4"] = state.endpoint.addressV4 ?? NSNull()
                payload["address_v6"] = state.endpoint.addressV6 ?? NSNull()
                payload["network_cidr"] = state.endpoint.networkCidr ?? NSNull()
                payload["network_cidr_v6"] = state.endpoint.networkCidrV6 ?? NSNull()
                payload["endpoint_host"] = state.endpoint.endpointHost ?? NSNull()
                payload["endpoint_port"] = state.endpoint.endpointPort
                payload["routes"] = state.endpoint.routes
                payload["created"] = state.endpoint.created
                payload["rotated"] = state.endpoint.rotated
                return payload
            }
        case "vm.tunnel_status":
            // Read-only: never enrolls, so it is safe for scripts and polling.
            return v2VmCall(id: id) {
                await Self.cloudTunnelStatusPayload(manager: VMTunnelManager())
            }
        case "vm.tunnel_up":
            // Explicit `cmux vpn up`: start now and pin the tunnel open until
            // `vpn down`. Returns once the outcome is known or the first
            // activation is waiting on the user (see `vm.tunnel_wait`).
            return v2VmCall(id: id, timeoutSeconds: 120) {
                guard let coordinator = await Self.cloudTunnelCoordinator(),
                      coordinator.backend.isNetworkExtension else {
                    throw CloudTunnelError.backendUnavailable(
                        await Self.cloudTunnelCoordinator()?.backend.unavailableReason ?? .entitlementMissing
                    )
                }
                if let refusal = await coordinator.beginUp(pin: true) {
                    throw refusal.error
                }
                let settled = await coordinator.waitForState(timeout: .seconds(60)) { state in
                    state == .awaitingApproval || !state.isSettling
                }
                // A start the policy refused after scheduling ends off; say
                // why instead of answering with a bare "off" payload.
                if settled == .off, let refusal = await coordinator.recordedStartRefusal() {
                    throw refusal.error
                }
                return await Self.cloudTunnelStatusPayload(manager: VMTunnelManager())
            }
        case "vm.tunnel_down":
            return v2VmCall(id: id, timeoutSeconds: 60) {
                if let coordinator = await Self.cloudTunnelCoordinator() {
                    await coordinator.requestDown()
                }
                return await Self.cloudTunnelStatusPayload(manager: VMTunnelManager())
            }
        case "vm.tunnel_wait":
            // Long-poll until the tunnel settles (up, off, or failed), so the
            // CLI can wait on the user's one-time extension approval without
            // sleeping and retrying.
            let requested = Self.socketWorkerInt(params["timeout_seconds"]) ?? 300
            let timeoutSeconds = min(max(requested, 1), 900)
            return v2VmCall(id: id, timeoutSeconds: TimeInterval(timeoutSeconds + 15)) {
                if let coordinator = await Self.cloudTunnelCoordinator() {
                    _ = await coordinator.waitForState(timeout: .seconds(timeoutSeconds)) { !$0.isSettling }
                }
                return await Self.cloudTunnelStatusPayload(manager: VMTunnelManager())
            }
        case "vm.tunnel_revoke":
            // Unenrolls this Mac server-side, deletes the VPN configuration on
            // app-managed builds, stops user-space links, and removes the local
            // config so a later explicit use re-enrolls from scratch.
            return v2VmCall(id: id) {
                if let coordinator = await Self.cloudTunnelCoordinator() {
                    try? await coordinator.revoke()
                }
                await CmuxTuiSurfaceProviderRegistry.shared.accessDidEnd()
                VMTunnelManager(purpose: .browser).removeLocalCredentials()
                VMTunnelManager(purpose: .terminal).removeLocalCredentials()
                try await VMClient.shared.revokeCloudAccess(deviceID: MobileHostIdentity.deviceID())
                return ["revoked": true]
            }
        default:
            return nil
        }
    }

    private nonisolated static func cloudTunnelCoordinator() async -> CloudTunnelCoordinator? {
        await MainActor.run { TerminalController.shared.cloudTunnel }
    }

    /// The shared shape of every tunnel verb's answer. Browser liveness comes
    /// only from Network Extension status. Terminal liveness comes from the
    /// user-space WireGuard hub.
    nonisolated static func cloudTunnelStatusPayload(manager: VMTunnelManager) async -> [String: Any] {
        let fingerprint = manager.storedDeviceFingerprint() ?? ""
        let config = manager.writtenConfig()
        let coordinator = await cloudTunnelCoordinator()
        let status = await coordinator?.status()
        let backend = status?.backend ?? CloudTunnelBackendSelector.live().select()
        let interfaceUp = backend.isNetworkExtension && status?.state == .up
        var payload: [String: Any] = [
            "config_path": manager.configURL.path,
            "config_present": config != nil,
            "config_digest": manager.configDigest() ?? NSNull(),
            "interface_name": manager.interfaceName,
            "interface_up": interfaceUp,
            "stale": false,
            "device_fingerprint": fingerprint,
            "network_extension_available": backend.isNetworkExtension,
            "backend": backend.wireName,
            "tunnel_state": status?.state.wireName ?? (backend.isNetworkExtension ? CloudTunnelState.off.wireName : "unmanaged"),
            "pinned": status?.isPinned ?? false,
        ]
        if let reason = backend.unavailableReason {
            payload["unavailable_reason"] = reason.rawValue
        }
        if let extensionBundleIdentifier = backend.extensionBundleIdentifier {
            payload["extension_bundle_id"] = extensionBundleIdentifier
        }
        if let failure = status?.state.failureMessage {
            payload["tunnel_error"] = failure
        }
        // Status stays read-only and current: it reports only the refusal
        // local state knows about right now (a fleet resolution that refused
        // also refilled the marker, so it shows up here), never resolves an
        // unknown machine count, and never echoes a past start's refusal
        // that the user may since have fixed.
        if backend.isNetworkExtension, let refusal = await coordinator?.knownStartRefusal() {
            payload["start_refusal"] = refusal.rawValue
            payload["start_refusal_message"] = refusal.error.description
        }
        let terminalManager = VMTunnelManager(purpose: .terminal)
        let hub = await MainActor.run { CmuxTuiSurfaceProviderRegistry.shared.wireGuardHub }
        let hubStatus = await hub?.status()
        payload["terminal_tunnel"] = [
            "device_fingerprint": terminalManager.storedDeviceFingerprint() ?? "",
            "config_path": terminalManager.configURL.path,
            "config_present": terminalManager.writtenConfig() != nil,
            "routes": terminalManager.configuredRoutes(),
            "hub_available": hub != nil,
            "hub_running": hubStatus?.running ?? false,
            "hub_socket": hubStatus?.socketPath ?? NSNull(),
            "hub_leases": hubStatus?.leases ?? 0,
            "hub_pinned": hubStatus?.pinnedByExternalClient ?? false,
            "hub_restart_attempts": hubStatus?.restartAttempts ?? 0,
            "hub_last_error": hubStatus?.lastError ?? NSNull(),
        ] as [String: Any]
        if let config {
            payload["addresses"] = VMTunnelManager.interfaceAddresses(in: config).sorted()
        }
        return payload
    }
}
