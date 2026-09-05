import Foundation

enum CloudTunnelFallbackReason: String, Sendable, Equatable {
    /// The signature lacks `com.apple.developer.networking.networkextension`
    /// with `packet-tunnel-provider-systemextension`.
    case entitlementMissing = "entitlement-missing"
    /// The signature lacks `com.apple.developer.system-extension.install`, so
    /// the app could not activate the extension even if it had it.
    case systemExtensionInstallEntitlementMissing = "system-extension-install-entitlement-missing"
    /// No `.systemextension` under `Contents/Library/SystemExtensions` (release
    /// signing removed it because the provisioning profile did not cover it).
    case extensionNotBundled = "extension-not-bundled"
}
