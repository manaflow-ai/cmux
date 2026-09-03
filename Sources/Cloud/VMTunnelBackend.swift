import Foundation
import Security

/// Which of the two bring-up paths for this Mac's Cloud VM tunnel a build can
/// actually drive.
///
/// The distinction is not a preference. `wgQuick` needs `sudo` in the user's
/// own terminal and only exists because an unentitled build cannot create a
/// utun; `networkExtension` is a real macOS VPN the app owns, approved once in
/// System Settings.
enum VMTunnelBackend: String, Equatable, Sendable {
    case networkExtension = "network-extension"
    case wgQuick = "wg-quick"
}

/// The resolved backend for the running build, plus the reason the app-managed
/// one is out of reach when it is.
///
/// Two facts decide it, and both are required:
///
/// 1. the signed entitlement grants a packet-tunnel provider, and
/// 2. this bundle actually embeds a packet-tunnel system extension to drive.
///
/// Checking only the entitlement is what made an entitled nightly claim the
/// NetworkExtension backend while still shelling out to `wg-quick`: the
/// Developer ID provisioning profile has carried the capability since
/// 2026-09-01, so the entitlement alone stopped meaning anything about whether
/// a provider exists. Requiring the embedded provider keeps the advertised
/// backend equal to the backend that will actually run, and flips to
/// `networkExtension` with no code change on the first build that ships the
/// extension.
struct VMTunnelBackendSelection: Equatable, Sendable {
    /// Why the app cannot manage the tunnel itself.
    enum UnavailableReason: String, Equatable, Sendable {
        /// The code signature grants no packet-tunnel provider. Ad-hoc-signed
        /// dev builds (`DEVELOPMENT_TEAM` empty) land here.
        case entitlementMissing = "entitlement-missing"
        /// Entitled, but no packet-tunnel system extension is embedded under
        /// `Contents/Library/SystemExtensions`, so there is no provider to
        /// start.
        case providerNotBundled = "provider-not-bundled"
    }

    let backend: VMTunnelBackend
    /// The bundle identifier of the embedded packet-tunnel provider, which is
    /// what `NETunnelProviderProtocol.providerBundleIdentifier` and
    /// `OSSystemExtensionRequest` both name. Non-nil exactly when `backend` is
    /// `.networkExtension`.
    let providerBundleIdentifier: String?
    /// Non-nil exactly when `backend` is `.wgQuick`.
    let unavailableReason: UnavailableReason?

    static let entitlementKey = "com.apple.developer.networking.networkextension"

    /// The two spellings Apple issues for a packet-tunnel provider. Developer
    /// ID distribution (nightly, RC, release) gets the `-systemextension`
    /// flavor; Mac App Store and Mac Development profiles get the bare
    /// app-extension value. A build may legitimately carry either, so both
    /// count.
    static let packetTunnelCapabilities: Set<String> = [
        "packet-tunnel-provider",
        "packet-tunnel-provider-systemextension",
    ]

    /// `NSExtensionPointIdentifier`-equivalent for a packet-tunnel system
    /// extension, declared under the extension's `NetworkExtension` →
    /// `NEProviderClasses` dictionary.
    static let packetTunnelProviderClassKey = "com.apple.networkextension.packet-tunnel"

    /// Whether an entitlement value grants a packet-tunnel provider. Takes the
    /// raw `Any?` a code signature yields, so a malformed or absent value is a
    /// plain `false` rather than a crash.
    static func packetTunnelEntitlementGranted(_ raw: Any?) -> Bool {
        guard let capabilities = raw as? [String] else { return false }
        return capabilities.contains { packetTunnelCapabilities.contains($0) }
    }

    static func resolve(entitlementValue: Any?, bundledProviderIdentifier: String?) -> Self {
        guard packetTunnelEntitlementGranted(entitlementValue) else {
            return Self(backend: .wgQuick, providerBundleIdentifier: nil, unavailableReason: .entitlementMissing)
        }
        guard let identifier = bundledProviderIdentifier, !identifier.isEmpty else {
            return Self(backend: .wgQuick, providerBundleIdentifier: nil, unavailableReason: .providerNotBundled)
        }
        return Self(backend: .networkExtension, providerBundleIdentifier: identifier, unavailableReason: nil)
    }

    /// The bundle identifier of the packet-tunnel system extension embedded in
    /// an app bundle, or nil when there is none.
    ///
    /// Outside the Mac App Store a packet-tunnel provider must ship as a system
    /// extension at `Contents/Library/SystemExtensions/<name>.systemextension`,
    /// so that directory is the whole search space. A bundle there is only this
    /// tunnel's provider if it declares the packet-tunnel provider class — a
    /// content-filter or DNS-proxy extension lives in the same directory and
    /// must not be mistaken for one.
    static func bundledProviderIdentifier(
        in bundleURL: URL,
        fileManager: FileManager = .default
    ) -> String? {
        let directory = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("SystemExtensions", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where entry.pathExtension == "systemextension" {
            let plistURL = entry
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Info.plist", isDirectory: false)
            guard let data = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil
                  ) as? [String: Any],
                  let identifier = plist["CFBundleIdentifier"] as? String,
                  !identifier.isEmpty,
                  declaresPacketTunnelProvider(plist) else { continue }
            return identifier
        }
        return nil
    }

    static func declaresPacketTunnelProvider(_ infoPlist: [String: Any]) -> Bool {
        guard let networkExtension = infoPlist["NetworkExtension"] as? [String: Any],
              let providerClasses = networkExtension["NEProviderClasses"] as? [String: Any] else {
            return false
        }
        guard let principalClass = providerClasses[packetTunnelProviderClassKey] as? String else { return false }
        return !principalClass.isEmpty
    }

    /// The selection for the running build. Neither input can change while the
    /// process lives — the code signature is fixed and the app bundle is
    /// read-only — so this is resolved once and reused, keeping the per-request
    /// `vm.tunnel_status` path off the filesystem.
    static let current: VMTunnelBackendSelection = {
        var entitlement: Any?
        if let task = SecTaskCreateFromSelf(nil) {
            entitlement = SecTaskCopyValueForEntitlement(task, entitlementKey as CFString, nil)
        }
        return resolve(
            entitlementValue: entitlement,
            bundledProviderIdentifier: bundledProviderIdentifier(in: Bundle.main.bundleURL)
        )
    }()

    /// One line naming the backend and, for `wg-quick`, why the app-managed
    /// tunnel is unavailable. Shown by `cmux vpn status`, so it has to be
    /// specific enough to act on.
    var statusDescription: String {
        switch backend {
        case .networkExtension:
            return String(
                localized: "cloud.tunnel.backend.networkExtension",
                defaultValue: "app-managed (NetworkExtension, no sudo)"
            )
        case .wgQuick:
            switch unavailableReason {
            case .entitlementMissing:
                return String(
                    localized: "cloud.tunnel.backend.wgQuickUnentitled",
                    defaultValue: "wg-quick (this build carries no packet-tunnel entitlement)"
                )
            case .providerNotBundled:
                return String(
                    localized: "cloud.tunnel.backend.wgQuickNoProvider",
                    defaultValue: "wg-quick (this build embeds no packet-tunnel system extension)"
                )
            case nil:
                return String(localized: "cloud.tunnel.backend.wgQuick", defaultValue: "wg-quick")
            }
        }
    }
}
