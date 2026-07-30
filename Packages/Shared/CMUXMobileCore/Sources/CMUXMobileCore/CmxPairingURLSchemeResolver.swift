import Foundation

/// Resolves the pairing target for the current process without global state.
public struct CmxPairingURLSchemeResolver: Sendable {
    private let currentIOSBundleIdentifier: String?
    private let targetIOSBundleIdentifier: String?
    private let macInstanceTag: String?

    /// Captures the current app identity and any explicit Mac pairing target.
    ///
    /// A Mac may set `CMUX_IOS_PAIRING_BUNDLE_IDENTIFIER` to any authoritative
    /// release-lane bundle id. Tagged Mac builds otherwise target their exact
    /// same-tag iOS bundle.
    public init(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        currentIOSBundleIdentifier = bundle.bundleIdentifier
        targetIOSBundleIdentifier =
            environment["CMUX_IOS_PAIRING_BUNDLE_IDENTIFIER"]
        macInstanceTag = environment["CMUX_TAG"]
    }

    init(
        currentIOSBundleIdentifier: String?,
        targetIOSBundleIdentifier: String?,
        macInstanceTag: String?
    ) {
        self.currentIOSBundleIdentifier = currentIOSBundleIdentifier
        self.targetIOSBundleIdentifier = targetIOSBundleIdentifier
        self.macInstanceTag = macInstanceTag
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
