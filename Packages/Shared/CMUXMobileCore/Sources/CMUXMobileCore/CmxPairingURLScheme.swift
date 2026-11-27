import Foundation

/// One validated URL scheme carried by a cmux pairing or attach deep link.
///
/// Every installed iOS bundle registers exactly one scheme derived from its
/// complete bundle identifier. Parsers also accept the two historical shared
/// schemes so an old QR remains scannable inside an already-open app, but new
/// apps never register those shared schemes with iOS.
public struct CmxPairingURLScheme {
    /// The validated, lowercase URL scheme.
    public let rawValue: String

    /// Creates the exact scheme registered by one installed iOS bundle.
    public init?(iOSBundleIdentifier: String?) {
        guard let namespace = MobileIOSAppNamespace(
            bundleIdentifier: iOSBundleIdentifier
        ) else {
            return nil
        }
        let scheme = namespace.pairingURLScheme.lowercased()
        guard Self.releaseSchemes.contains(scheme)
                || scheme == Self.untaggedDevelopmentScheme
                || scheme.hasPrefix(Self.developmentPrefix) else {
            return nil
        }
        rawValue = scheme
    }

    /// Parses a classifiable bundle-specific or historical shared pairing
    /// scheme. Unknown release-like namespaces fail closed so account preflight
    /// cannot be bypassed by a syntactically valid but unclassified scheme.
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
              ) != nil,
              Self.releaseSchemes.contains(normalized)
                || normalized == Self.untaggedDevelopmentScheme
                || normalized.hasPrefix(Self.developmentPrefix) else {
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
            || rawValue == Self.untaggedDevelopmentScheme
            || rawValue.hasPrefix(Self.developmentPrefix)
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

    private static let untaggedDevelopmentScheme = "cmux-ios-dev.cmux.ios"
    private static let developmentPrefix = "cmux-ios-dev.cmux.ios."

    private static let releaseSchemes: Set<String> = [
        release,
        "cmux-ios-com.cmux.app",
        "cmux-ios-dev.cmux.app.beta",
        "cmux-ios-dev.cmux.app.internal",
        "cmux-ios-dev.cmux.app.demo",
    ]
}

extension CmxPairingURLScheme: Equatable, Sendable {}
