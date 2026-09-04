import CmuxFoundation
import Foundation
import NetworkExtension

/// How this Mac's tunnel to the Cloud VM private network is actually held up.
///
/// There are two, and which one is available is decided by code signing rather
/// than by preference:
///
/// - **NetworkExtension** — the app owns the tunnel itself. Connecting costs
///   one system VPN-permission dialog (a click, not a password), and after
///   that the app starts and stops it programmatically. Requires
///   `com.apple.developer.networking.networkextension` with
///   `packet-tunnel-provider`, which Apple grants per team, plus a packet
///   tunnel provider extension to run the tunnel in.
/// - **LaunchDaemon** — a root launchd job runs `wg-quick`. Works on any
///   build, including unsigned local ones, at the cost of an administrator
///   prompt at install and a job living outside the app bundle.
///
/// The daemon path is what ships today and is not going away: it is the only
/// thing that works on a build without the entitlement, which includes every
/// local development build.
protocol CloudTunnelBackend: Sendable {
    /// Whether this backend can run on this build at all.
    static var isAvailable: Bool { get }

    /// Whether the tunnel is carrying traffic right now.
    func isConnected() async -> Bool

    /// Whether the tunnel comes back on its own after a restart.
    func isPersistent() async -> Bool

    /// Brings the tunnel up for `configuration`, prompting if the backend
    /// needs authorization it does not yet have.
    func connect(configuration: TunnelConfiguration) async throws

    /// Takes the tunnel down and stops it coming back.
    func disconnect() async throws
}

/// What a backend needs to raise a tunnel, independent of how it raises it.
struct TunnelConfiguration: Sendable {
    /// wg-quick interface name, which also names the launchd job and the
    /// saved VPN configuration.
    let interfaceName: String
    /// Path to the completed wg-quick config the app wrote.
    let configPath: String
    /// The config's text. NetworkExtension passes settings to its provider
    /// rather than pointing it at a file the extension may not be able to read.
    let configText: String
}

/// Tunnel held by a packet tunnel provider inside the app's own extension.
///
/// Preferred when available: the person clicks Allow on a system dialog once
/// and never sees an administrator prompt, nothing is installed outside the
/// app bundle, and uninstalling the app takes the tunnel with it.
///
/// Two things must exist before this can work, neither of which is code in
/// this file:
///
/// 1. The entitlement, granted by Apple to the signing team and added to the
///    app and the extension. ``VMTunnelManager/networkExtensionAvailable()``
///    reports whether the running build has it.
/// 2. A packet tunnel provider extension target named by
///    ``providerBundleIdentifier``, containing a WireGuard implementation.
///
/// Without both, `connect` fails when the system cannot find the provider.
/// That is why availability is gated on the entitlement rather than tried
/// hopefully: a build that lacks it must fall back rather than show a VPN
/// prompt that cannot succeed.
struct NetworkExtensionTunnelBackend: CloudTunnelBackend {
    static var isAvailable: Bool { VMTunnelManager.networkExtensionAvailable() }

    /// The extension that runs the tunnel, by convention a child of the app's
    /// bundle id so tagged development builds get their own provider rather
    /// than fighting over one.
    static var providerBundleIdentifier: String {
        let app = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        return "\(app).network-extension"
    }

    enum BackendError: Error, CustomStringConvertible {
        case unavailable
        case providerMissing

        var description: String {
            switch self {
            case .unavailable:
                return String(
                    localized: "cloud.tunnel.ne.unavailable",
                    defaultValue: "This build cannot manage the VPN itself."
                )
            case .providerMissing:
                return String(
                    localized: "cloud.tunnel.ne.providerMissing",
                    defaultValue: "cmux could not start its VPN. Reinstall cmux and try again."
                )
            }
        }
    }

    func isConnected() async -> Bool {
        guard let manager = try? await Self.loadManager() else { return false }
        switch manager.connection.status {
        case .connected, .connecting, .reasserting:
            return manager.connection.status == .connected
        default:
            return false
        }
    }

    /// On-demand is what makes this persistent: the system brings the tunnel
    /// back after a restart without the app running.
    func isPersistent() async -> Bool {
        guard let manager = try? await Self.loadManager() else { return false }
        return manager.isOnDemandEnabled
    }

    func connect(configuration: TunnelConfiguration) async throws {
        guard Self.isAvailable else { throw BackendError.unavailable }
        let manager = try await Self.loadManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerBundleIdentifier
        // The provider needs an address to describe the tunnel; the real peer
        // lives in the configuration below.
        proto.serverAddress = configuration.interfaceName
        // The extension cannot read the app's container, so the config travels
        // with the saved configuration rather than as a path.
        proto.providerConfiguration = ["wgQuickConfig": configuration.configText]
        manager.protocolConfiguration = proto
        manager.localizedDescription = "cmux (\(configuration.interfaceName))"
        manager.isEnabled = true
        // Saving is what raises the system's VPN-permission dialog the first
        // time. It is a click, not a password, and it is asked once.
        try await manager.saveToPreferences()
        // A save invalidates the in-memory object, so the started tunnel must
        // come from a fresh load.
        let saved = try await Self.loadManager()
        do {
            try saved.connection.startVPNTunnel()
        } catch {
            throw BackendError.providerMissing
        }
    }

    func disconnect() async throws {
        guard let manager = try? await Self.loadManager() else { return }
        manager.connection.stopVPNTunnel()
        manager.isOnDemandEnabled = false
        manager.isEnabled = false
        try? await manager.saveToPreferences()
    }

    /// The app's own saved VPN configuration, or a new one. Matching on the
    /// provider bundle id keeps this from adopting a VPN the person set up
    /// themselves.
    private static func loadManager() async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let mine = managers.first { manager in
            (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == providerBundleIdentifier
        }
        return mine ?? NETunnelProviderManager()
    }
}

/// Tunnel held by a root launchd job running `wg-quick`, which is what ships
/// today. See ``CmuxVPNAutostart``.
struct LaunchDaemonTunnelBackend: CloudTunnelBackend {
    /// Always: this is the fallback, and a build with no entitlement has
    /// nothing else.
    static var isAvailable: Bool { true }

    func isConnected() async -> Bool {
        VMTunnelManager().wgQuickInterfaceUp()
    }

    func isPersistent() async -> Bool {
        CmuxVPNAutostart(interfaceName: VMTunnelManager().interfaceName).isInstalled()
    }

    func connect(configuration: TunnelConfiguration) async throws {
        let interfaceName = configuration.interfaceName
        let configPath = configuration.configPath
        _ = try await Task.detached(priority: .userInitiated) {
            try VMTunnelAutostart.install(interfaceName: interfaceName, userConfigPath: configPath)
        }.value
    }

    func disconnect() async throws {
        let interfaceName = configuration_interfaceName()
        _ = try await Task.detached(priority: .userInitiated) {
            try VMTunnelAutostart.uninstall(interfaceName: interfaceName)
        }.value
    }

    private func configuration_interfaceName() -> String {
        VMTunnelManager().interfaceName
    }
}

/// Picks the backend this build can actually use.
///
/// Not a preference: an unentitled build has exactly one option, and asking it
/// to use NetworkExtension would produce a VPN prompt that cannot succeed.
enum CloudTunnelBackendFactory {
    static func make() -> any CloudTunnelBackend {
        NetworkExtensionTunnelBackend.isAvailable
            ? NetworkExtensionTunnelBackend()
            : LaunchDaemonTunnelBackend()
    }

    /// Whether the tunnel is app-managed, which is what the UI needs to know
    /// to promise "one click" instead of "asks for your password".
    static var isAppManaged: Bool { NetworkExtensionTunnelBackend.isAvailable }
}
