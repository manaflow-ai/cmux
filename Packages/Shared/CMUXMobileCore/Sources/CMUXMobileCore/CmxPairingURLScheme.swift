import Foundation

/// One validated URL scheme carried by a cmux pairing or attach deep link.
///
/// Every installed iOS bundle registers exactly one scheme derived from its
/// complete bundle identifier. Parsers also accept the two historical shared
/// schemes so an old QR remains scannable inside an already-open app, but new
/// apps never register those shared schemes with iOS.
public struct CmxPairingURLScheme: Equatable, Sendable {
    /// The validated, lowercase URL scheme.
    public let rawValue: String

    /// Creates the exact scheme registered by one installed iOS bundle.
    public init?(iOSBundleIdentifier: String?) {
        guard let namespace = MobileIOSAppNamespace(
            bundleIdentifier: iOSBundleIdentifier
        ) else {
            return nil
        }
        rawValue = namespace.pairingURLScheme
    }

    /// Parses a current bundle-specific or historical shared pairing scheme.
    public init?(rawValue: String?) {
        guard let rawValue else { return nil }
        let normalized = rawValue.lowercased()
        if Self.all.contains(normalized) {
            self.rawValue = normalized
            return
        }
        let prefix = "cmux-ios-"
        guard normalized.hasPrefix(prefix),
              MobileIOSAppNamespace(
                bundleIdentifier: String(normalized.dropFirst(prefix.count))
              ) != nil else {
            return nil
        }
        self.rawValue = normalized
    }

    /// Parses the scheme from a complete pairing URL.
    public init?(urlString: String) {
        guard urlString.contains("://"),
              let components = URLComponents(string: urlString),
              let scheme = CmxPairingURLScheme(rawValue: components.scheme) else {
            return nil
        }
        self = scheme
    }

    /// Whether this scheme identifies a tagged iOS development build.
    public var isDevelopment: Bool {
        rawValue == Self.development
            || rawValue.hasPrefix("cmux-ios-dev.cmux.ios.")
    }

    /// Whether this scheme identifies an App Store or TestFlight build.
    public var isRelease: Bool {
        Self.releaseSchemes.contains(rawValue)
    }

    /// Historical shared Release scheme. Parse-only in new iOS builds.
    public static let release = "cmux-ios"

    /// Historical shared development scheme. Parse-only in new iOS builds.
    public static let development = "cmux-ios-dev"

    /// Historical schemes retained for source compatibility and old QR tests.
    public static let all: [String] = [release, development]

    private static let releaseSchemes: Set<String> = [
        release,
        "cmux-ios-com.cmux.app",
        "cmux-ios-dev.cmux.app.beta",
        "cmux-ios-dev.cmux.app.internal",
        "cmux-ios-dev.cmux.app.demo",
    ]
}

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
