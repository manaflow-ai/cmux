import Foundation

/// Bundle-specific URL schemes carried by cmux pairing/attach deep links.
///
/// Every installed iOS bundle registers exactly one scheme derived from its
/// complete bundle identifier. Parsers also accept the two historical shared
/// schemes so an old QR remains scannable inside an already-open app, but new
/// apps never register those shared schemes with iOS.
///
/// lint:allow namespace-type — the build channel's URL scheme is a pure
/// compile-time constant set with no per-instance state to inject; these
/// scheme strings and the stateless pairing-scheme predicates are a genuine
/// namespace, like the sanctioned FFI/seam holders.
public struct CmxPairingURLScheme {
    private init() {}

    /// Historical shared Release scheme. Parse-only in new iOS builds.
    public static let release = "cmux-ios"

    /// Historical shared development scheme. Parse-only in new iOS builds.
    public static let development = "cmux-ios-dev"

    /// Historical schemes retained for source compatibility and old QR tests.
    public static let all: [String] = [release, development]

    /// The scheme this build emits in pairing QRs and attach URLs.
    public static var current: String {
        if let iOSBundleIdentifier = resolvedIOSBundleIdentifier(),
           let namespace = MobileIOSAppNamespace(bundleIdentifier: iOSBundleIdentifier) {
            return namespace.pairingURLScheme
        }
        return release
    }

    public static func scheme(forIOSBundleIdentifier bundleIdentifier: String) -> String {
        MobileIOSAppNamespace(bundleIdentifier: bundleIdentifier)?.pairingURLScheme ?? release
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

    private static func resolvedIOSBundleIdentifier(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        #if os(iOS)
        return bundle.bundleIdentifier
        #else
        if let tag = environment["CMUX_TAG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !tag.isEmpty,
           tag != "default" {
            return "dev.cmux.ios.\(tag)"
        }
        return "com.cmux.app"
        #endif
    }
}
