import Foundation
import NetworkExtension
import os

/// Runs this Mac's WireGuard tunnel to its Cloud VM private network inside the
/// app's own VPN extension.
///
/// This is the alternative to the root launchd job that runs `wg-quick`: the
/// system starts and stops this provider, so connecting costs one
/// VPN-permission dialog instead of an administrator password, and nothing is
/// installed outside the app bundle.
///
/// **This provider cannot carry traffic yet.** It has no WireGuard
/// implementation, because there is not currently one that builds here:
///
/// - `wireguard-apple` on `master` does not resolve. Its manifest declares
///   `.macOS(.v12)` / `.iOS(.v15)` under `swift-tools-version:5.3`, where
///   those cases do not exist, and SwiftPM refuses it ("'v12' is
///   unavailable").
/// - `1.0.15-26`, the newest revision whose manifest is self-consistent, then
///   fails to compile: `WireGuardKitC.h` uses `u_int32_t` and `u_char`
///   without including `<sys/types.h>`, which the current toolchain's module
///   build rejects. Disabling explicit modules on this target does not help,
///   because those settings do not reach a remote package's C target.
///
/// Picking the way through that is a dependency decision rather than a coding
/// one -- vendor and patch WireGuardKit, adopt a maintained fork, or wait for
/// upstream -- so it is deliberately not made here. Everything around it is
/// real: the target, its embedding in the app, the entitlement, and the
/// app-side control in ``NetworkExtensionTunnelBackend``.
///
/// Until then this fails cleanly, and nothing reaches it: the app only selects
/// the NetworkExtension backend when the entitlement is present, which no
/// build carries yet.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "com.cmuxterm.app.tunnel", category: "wireguard")

    enum ProviderError: Error, LocalizedError {
        case missingConfiguration
        case noWireGuardImplementation

        var errorDescription: String? {
            switch self {
            case .missingConfiguration:
                return "The tunnel was started without a configuration."
            case .noWireGuardImplementation:
                return "This build of the cmux tunnel has no WireGuard implementation."
            }
        }
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // The app hands the tunnel over as wg-quick text in
        // `providerConfiguration`, not as a path: an extension runs in its own
        // sandbox and cannot read the app's container. Validating it here
        // keeps that contract honest even while the tunnel cannot be raised.
        guard
            let proto = protocolConfiguration as? NETunnelProviderProtocol,
            let quickConfig = proto.providerConfiguration?["wgQuickConfig"] as? String,
            !quickConfig.isEmpty
        else {
            os_log("tunnel start rejected: no configuration", log: log, type: .error)
            completionHandler(ProviderError.missingConfiguration)
            return
        }
        os_log(
            "tunnel start rejected: no WireGuard implementation is linked",
            log: log,
            type: .error
        )
        completionHandler(ProviderError.noWireGuardImplementation)
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
