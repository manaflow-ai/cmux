import Foundation

/// Bundle-specific URL schemes carried by cmux pairing/attach deep links.
///
/// Every installed iOS bundle registers exactly one scheme derived from its
/// complete bundle identifier. Parsers also accept the two historical shared
/// schemes so an old QR remains scannable inside an already-open app, but new
/// apps never register those shared schemes with iOS.
///
public struct CmxPairingURLScheme: Equatable, Sendable {
    public let rawValue: String

    public init?(iOSBundleIdentifier: String?) {
        guard let namespace = MobileIOSAppNamespace(
            bundleIdentifier: iOSBundleIdentifier
        ) else {
            return nil
        }
        rawValue = namespace.pairingURLScheme
    }

    private init(namespace: MobileIOSAppNamespace) {
        rawValue = namespace.pairingURLScheme
    }

    /// Historical shared Release scheme. Parse-only in new iOS builds.
    public static let release = "cmux-ios"

    /// Historical shared development scheme. Parse-only in new iOS builds.
    public static let development = "cmux-ios-dev"

    /// Historical schemes retained for source compatibility and old QR tests.
    public static let all: [String] = [release, development]

    /// The scheme this build emits in pairing QRs and attach URLs.
    public static var current: String? {
        resolvedCurrent()?.rawValue
    }

    public static func scheme(forIOSBundleIdentifier bundleIdentifier: String) -> String? {
        CmxPairingURLScheme(iOSBundleIdentifier: bundleIdentifier)?.rawValue
    }

    public static func isPairingScheme(_ scheme: String?) -> Bool {
        guard let scheme else { return false }
        let normalized = scheme.lowercased()
        if all.contains(where: { $0 == normalized }) {
            return true
        }
        let prefix = "cmux-ios-"
        guard normalized.hasPrefix(prefix) else { return false }
        return MobileIOSAppNamespace(
            bundleIdentifier: String(normalized.dropFirst(prefix.count))
        ) != nil
    }

    public static func hasPairingScheme(_ rawValue: String) -> Bool {
        guard let components = URLComponents(string: rawValue),
              rawValue.contains("://")
        else {
            return false
        }
        return isPairingScheme(components.scheme)
    }

    public static func isDevelopmentPairingScheme(_ scheme: String?) -> Bool {
        guard let scheme else { return false }
        if development.caseInsensitiveCompare(scheme) == .orderedSame {
            return true
        }
        let normalized = scheme.lowercased()
        return normalized.hasPrefix("cmux-ios-dev.cmux.ios.")
    }

    public static func isReleasePairingScheme(_ scheme: String?) -> Bool {
        guard let scheme else { return false }
        if release.caseInsensitiveCompare(scheme) == .orderedSame {
            return true
        }
        let normalized = scheme.lowercased()
        return normalized.hasPrefix("cmux-ios-com.cmux.app")
            || normalized.hasPrefix("cmux-ios-dev.cmux.app.")
    }

    static func resolvedCurrent(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CmxPairingURLScheme? {
        #if os(iOS)
        guard let namespace = MobileIOSAppNamespace(
            bundleIdentifier: bundle.bundleIdentifier
        ) else {
            return nil
        }
        #else
        guard let namespace = MobileIOSAppNamespace(
            pairedMacInstanceTag: environment["CMUX_TAG"]
        ) else {
            return nil
        }
        #endif
        return CmxPairingURLScheme(namespace: namespace)
    }
}
