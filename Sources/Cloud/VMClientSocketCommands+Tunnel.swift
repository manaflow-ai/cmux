import Foundation

/// `vm.tunnel_*`: this Mac's membership in the user's private Cloud VM
/// network. Enrollment and status work on every build; `up`, `down`, and
/// `wait` drive the app-managed tunnel and answer with the wg-quick backend
/// (so `cmux vpn` falls back to sudo wg-quick) on builds without it.
///
/// Trust boundary: the completed config never crosses the socket. `tunnel_config`
/// returns only the path of the 0600 file the app wrote, the same boundary every
/// other `vm.` verb already accepts.
extension TerminalController {
    nonisolated func socketWorkerCloudTunnelResponse(
        method: String,
        id: Any?,
        params: [String: Any]
    ) -> String? {
        switch method {
        case "vm.tunnel_config":
            // Enrolls this Mac (idempotent) and writes the completed wg-quick
            // config. `cmux vpn up` on the wg-quick backend brings up the path
            // this returns; on the app-managed backend `vm.tunnel_up` does it.
            return v2VmCall(id: id) {
                let manager = VMTunnelManager()
                let state = try await manager.enroll(client: VMClient.shared)
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
                        await Self.cloudTunnelCoordinator()?.backend.fallbackReason ?? .entitlementMissing
                    )
                }
                await coordinator.beginUp(pin: true)
                _ = await coordinator.waitForState(timeout: .seconds(60)) { state in
                    state == .awaitingApproval || !state.isSettling
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
            // app-managed builds, and removes the local config so a later start
            // re-enrolls from scratch.
            return v2VmCall(id: id) {
                let manager = VMTunnelManager()
                let fingerprint = try manager.deviceFingerprint()
                if let coordinator = await Self.cloudTunnelCoordinator() {
                    try await coordinator.revoke()
                }
                try await VMClient.shared.revokeTunnel(deviceFingerprint: fingerprint)
                try? FileManager.default.removeItem(at: manager.configURL)
                return ["revoked": true]
            }
        default:
            return nil
        }
    }

    private nonisolated static func cloudTunnelCoordinator() async -> CloudTunnelCoordinator? {
        await MainActor.run { TerminalController.shared.cloudTunnel }
    }

    /// The shared shape of every tunnel verb's answer: on-disk enrollment
    /// state, the live interface, and the app-managed tunnel's backend/state.
    nonisolated static func cloudTunnelStatusPayload(manager: VMTunnelManager) async -> [String: Any] {
        let fingerprint = (try? manager.deviceFingerprint()) ?? ""
        let config = manager.writtenConfig()
        let coordinator = await cloudTunnelCoordinator()
        let status = await coordinator?.status()
        let backend = status?.backend ?? CloudTunnelBackendSelector.live().select()
        var payload: [String: Any] = [
            "config_path": manager.configURL.path,
            "config_present": config != nil,
            "interface_name": VMTunnelManager.interfaceName,
            "interface_up": manager.wgQuickInterfaceUp(),
            "device_fingerprint": fingerprint,
            "network_extension_available": backend.isNetworkExtension,
            "backend": backend.wireName,
            "tunnel_state": status?.state.wireName ?? (backend.isNetworkExtension ? CloudTunnelState.off.wireName : "unmanaged"),
            "pinned": status?.isPinned ?? false,
        ]
        if let reason = backend.fallbackReason {
            payload["fallback_reason"] = reason.rawValue
        }
        if let extensionBundleIdentifier = backend.extensionBundleIdentifier {
            payload["extension_bundle_id"] = extensionBundleIdentifier
        }
        if let failure = status?.state.failureMessage {
            payload["tunnel_error"] = failure
        }
        if let config {
            payload["addresses"] = VMTunnelManager.interfaceAddresses(in: config).sorted()
        }
        return payload
    }
}
