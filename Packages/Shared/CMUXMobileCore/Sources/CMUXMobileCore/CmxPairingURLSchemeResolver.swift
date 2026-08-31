import Foundation

/// Resolves the pairing scheme for the current process without global state.
public struct CmxPairingURLSchemeResolver: Sendable {
    private let currentIOSBundleIdentifier: String?
    private let targetIOSBundleIdentifier: String?
    private let macInstanceTag: String?
    private let isDevelopmentBuild: Bool

    /// Captures the current app identity and any explicit automation override.
    ///
    /// `CMUX_IOS_PAIRING_BUNDLE_IDENTIFIER` remains an automation-only override
    /// for scripts and tests. Normal official Macs emit the canonical App Store
    /// scheme; tagged Mac builds otherwise target their exact same-tag iOS
    /// bundle.
    public init(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        currentIOSBundleIdentifier = bundle.bundleIdentifier
        targetIOSBundleIdentifier =
            environment["CMUX_IOS_PAIRING_BUNDLE_IDENTIFIER"]
        macInstanceTag = environment["CMUX_TAG"]
        #if DEBUG
        isDevelopmentBuild = true
        #else
        isDevelopmentBuild = false
        #endif
    }

    init(
        currentIOSBundleIdentifier: String?,
        targetIOSBundleIdentifier: String?,
        macInstanceTag: String?,
        isDevelopmentBuild: Bool
    ) {
        self.currentIOSBundleIdentifier = currentIOSBundleIdentifier
        self.targetIOSBundleIdentifier = targetIOSBundleIdentifier
        self.macInstanceTag = macInstanceTag
        self.isDevelopmentBuild = isDevelopmentBuild
    }

    /// The exact scheme this process should emit, or `nil` on invalid identity.
    public var resolved: CmxPairingURLScheme? {
        #if os(iOS)
        return CmxPairingURLScheme(
            iOSBundleIdentifier: currentIOSBundleIdentifier
        )
        #else
        if let targetIOSBundleIdentifier {
            return CmxPairingURLScheme(
                iOSBundleIdentifier: targetIOSBundleIdentifier
            )
        }
        let normalizedTag = macInstanceTag?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedTag == nil || normalizedTag?.isEmpty == true {
            return CmxPairingURLScheme(
                iOSBundleIdentifier: isDevelopmentBuild
                    ? "dev.cmux.ios"
                    : "com.cmux.app"
            )
        }
        // Stable and Nightly are official Mac lanes even when a launcher
        // happens to provide the lane name through CMUX_TAG. They must emit the
        // one canonical release QR, never a synthetic tagged-DEV destination.
        if normalizedTag == "default" || normalizedTag == "nightly" {
            return CmxPairingURLScheme(iOSBundleIdentifier: "com.cmux.app")
        }
        guard let namespace = MobileIOSAppNamespace(
            pairedMacInstanceTag: macInstanceTag
        ) else {
            return nil
        }
        return CmxPairingURLScheme(
            iOSBundleIdentifier: namespace.bundleIdentifier
        )
        #endif
    }
}
