import Foundation
import Security

/// Picks the ``CloudTunnelBackend`` from what the running binary can actually
/// do: the entitlements in its signature and the extension in its bundle.
///
/// All inputs are injected so the decision is testable without a signed
/// bundle; ``live(bundle:)`` wires the real signature and bundle. Reading the
/// signature rather than trying to configure a manager means an unentitled
/// build never shows the user a doomed VPN prompt.
struct CloudTunnelBackendSelector: Sendable {
    static let networkExtensionEntitlement = "com.apple.developer.networking.networkextension"
    static let systemExtensionInstallEntitlement = "com.apple.developer.system-extension.install"
    static let packetTunnelSystemExtensionCapability = "packet-tunnel-provider-systemextension"
    static let systemExtensionsFolder = "Contents/Library/SystemExtensions"

    /// Capabilities listed under the NetworkExtension entitlement, or empty.
    let networkExtensionCapabilities: @Sendable () -> [String]
    /// Whether `com.apple.developer.system-extension.install` is granted.
    let canInstallSystemExtensions: @Sendable () -> Bool
    /// `CFBundleIdentifier` of the bundled `.systemextension`, if any.
    let bundledExtensionIdentifier: @Sendable () -> String?

    func select() -> CloudTunnelBackend {
        guard networkExtensionCapabilities().contains(Self.packetTunnelSystemExtensionCapability) else {
            return .unavailable(.entitlementMissing)
        }
        guard canInstallSystemExtensions() else {
            return .unavailable(.systemExtensionInstallEntitlementMissing)
        }
        guard let identifier = bundledExtensionIdentifier() else {
            return .unavailable(.extensionNotBundled)
        }
        return .networkExtension(extensionBundleIdentifier: identifier)
    }

    /// The real thing: this process's signed entitlements and `bundle`'s
    /// `Contents/Library/SystemExtensions`.
    static func live(bundle: Bundle = .main) -> CloudTunnelBackendSelector {
        let bundleURL = bundle.bundleURL
        return CloudTunnelBackendSelector(
            networkExtensionCapabilities: {
                (signedEntitlement(networkExtensionEntitlement) as? [String]) ?? []
            },
            canInstallSystemExtensions: {
                (signedEntitlement(systemExtensionInstallEntitlement) as? Bool) ?? false
            },
            bundledExtensionIdentifier: {
                bundledSystemExtensionIdentifier(in: bundleURL)
            }
        )
    }

    /// One entitlement value from the running process's code signature.
    static func signedEntitlement(_ key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }

    /// `CFBundleIdentifier` of the first `.systemextension` embedded in the app
    /// at `bundleURL`, read from its Info.plist. This is the identifier the app
    /// activates and configures, so it is discovered from the artifact that
    /// ships rather than derived from a naming convention.
    static func bundledSystemExtensionIdentifier(
        in bundleURL: URL,
        fileManager: FileManager = .default
    ) -> String? {
        let folder = bundleURL.appendingPathComponent(systemExtensionsFolder, isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where entry.pathExtension == "systemextension" {
            let plistURL = entry.appendingPathComponent("Contents/Info.plist", isDirectory: false)
            guard let data = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let identifier = plist["CFBundleIdentifier"] as? String,
                  !identifier.isEmpty else { continue }
            return identifier
        }
        return nil
    }
}
